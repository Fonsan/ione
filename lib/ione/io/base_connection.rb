# encoding: utf-8

module Ione
  module Io
    class BaseConnection
      attr_reader :host, :port

      # @private
      def initialize(host, port, unblocker)
        @host = host
        @port = port
        @unblocker = unblocker
        @state = :connecting
        @writable = false
        @lock = Mutex.new
        @write_buffer = ByteBuffer.new
        @closed_promise = Promise.new
        @data_stream = Stream::PushStream.new
      end

      # Closes the connection
      #
      # @return [true, false] returns false if the connection was already closed
      def close(cause=nil)
        @lock.synchronize do
          return false if @state == :closed
          @state = :closed
          @writable = false
        end
        if @io
          begin
            @io.close
            @io = nil
          rescue SystemCallError, IOError
            # nothing to do, the socket was most likely already closed
          end
        end
        if cause && !cause.is_a?(IoError)
          cause = ConnectionClosedError.new(cause.message)
        end
        if cause
          @closed_promise.fail(cause)
        else
          @closed_promise.fulfill(self)
        end
        true
      end

      # Wait for the connection's buffers to empty and then close it.
      #
      # This method is almost always preferable to {#close}.
      #
      # @return [Ione::Future] a future that resolves to the connection when it
      #   has closed
      def drain
        @state = :draining
        close unless @writable
        @closed_promise.future
      end

      # @private
      def connecting?
        @state == :connecting
      end

      # Returns true if the connection is connected
      def connected?
        @state == :connected
      end

      # Returns true if the connection is closed
      def closed?
        @state == :closed
      end

      # @private
      def writable?
        @writable && @state != :closed
      end

      # Returns a stream of data chunks received by this connection
      #
      # It is very important that you don't do any heavy lifting in subscribers
      # to this stream since they will be called from the IO reactor thread.
      #
      # @example Transforming a stream of data chunks to a stream of lines
      #   data_chunk_stream = connection.to_stream
      #   line_stream = data_chunk_stream.aggregate(ByteBuffer.new) do |chunk, downstream, buffer|
      #     buffer << chunk
      #     while (newline_index = buffer.index("\n"))
      #       downstream << buffer.read(newline_index + 1)
      #     end
      #     buffer
      #   end
      #   line_stream.each do |line|
      #     puts line
      #   end
      #
      # @return [Ione::Stream<String>]
      def to_stream
        @data_stream
      end

      # Register to receive notifications when new data is read from the socket.
      #
      # You should only call this method in your protocol handler constructor.
      #
      # Only one callback can be registered, if you register multiple times only
      # the last one will receive notifications. This is not meant as a general
      # event system, it's just for protocol handlers to receive data from their
      # connection. If you want multiple listeners you need to implement that
      # yourself in your protocol handler.
      #
      # It is very important that you don't do any heavy lifting in the callback
      # since it is called from the IO reactor thread, and as long as the
      # callback is working the reactor can't handle any IO and no other
      # callbacks can be called.
      #
      # Errors raised by the callback will be ignored.
      #
      # @yield [String] the new data
      def on_data(&listener)
        @data_stream.subscribe(listener)
        nil
      end

      # Register to receive a notification when the socket is closed, both for
      # expected and unexpected reasons.
      #
      # Errors raised by the callback will be ignored.
      #
      # @yield [error, nil] the error that caused the socket to close, or nil if
      #   the socket closed with #close
      def on_closed(&listener)
        @closed_promise.future.on_value { listener.call(nil) }
        @closed_promise.future.on_failure { |e| listener.call(e) }
      end

      # Write bytes to the socket.
      #
      # You can either pass in bytes (as a string or as a `ByteBuffer`), or you
      # can use the block form of this method to get access to the connection's
      # internal buffer.
      #
      # @yieldparam buffer [Ione::ByteBuffer] the connection's internal buffer
      # @param bytes [String, Ione::ByteBuffer] the data to write to the socket
      def write(bytes=nil)
        if @state == :connected || @state == :connecting
          @lock.lock
          begin
            if block_given?
              yield @write_buffer
            elsif bytes
              @write_buffer.append(bytes)
            end
            @writable = !@write_buffer.empty?
          ensure
            @lock.unlock
          end
          @unblocker.unblock
        end
      end

      # @private
      def flush
        if @state == :connected || @state == :draining
          @lock.lock
          begin
            if @writable
              bytes_written = @io.write_nonblock(@write_buffer.cheap_peek)
              @write_buffer.discard(bytes_written)
            end
            @writable = !@write_buffer.empty?
            if @state == :draining && !@writable
              close
            end
          ensure
            @lock.unlock
          end
        end
      rescue => e
        close(e)
      end

      # @private
      def read
        @data_stream << @io.read_nonblock(2**16)
      rescue => e
        close(e)
      end

      # @private
      def to_io
        @io
      end

      def to_s
        %(#<#{self.class.name} #{@state} #{@host}:#{@port}>)
      end
    end
  end
end