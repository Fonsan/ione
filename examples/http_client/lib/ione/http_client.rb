# encoding: utf-8

require 'ione'
require 'http_parser'
require 'uri'


module Ione
  class HttpClient
    def initialize
      @reactor = Io::IoReactor.new
    end

    def start
      @reactor.start.map(self)
    end

    def stop
      @reactor.stop.map(self)
    end

    def get(url, headers={})
      uri = URI.parse(url)
      f = @reactor.connect(uri.host, uri.port, timeout: 1) do |connection|
        HttpProtocolHandler.new(connection)
      end
      f.flat_map do |handler|
        handler.send_get(uri.path, uri.query, headers)
      end
    end
  end

  class HttpProtocolHandler
    def initialize(connection)
      @connection = connection
      @connection.on_data(&method(:process_data))
      @http_parser = Http::Parser.new(self)
      @promises = []
    end

    def send_get(path, query, headers)
      @connection.write do |buffer|
        buffer << 'GET '
        buffer << path
        if query && !query.empty?
          buffer << '?'
          buffer << query
        end
        buffer << " HTTP/1.1\r\n"
        headers.each do |key, value|
          buffer << key
          buffer << ':'
          buffer << value
          buffer << "\r\n"
        end
        buffer << "\r\n"
      end
      @promises << Promise.new
      @promises.last.future
    end

    def process_data(new_data)
      @http_parser << new_data
    end

    def on_message_begin
      @headers = nil
      @body = ''
    end

    def on_headers_complete(headers)
      @headers = headers
    end

    def on_body(chunk)
      @body << chunk
    end

    def on_message_complete
      response = HttpResponse.new(@http_parser.status_code, @headers, @body)
      @promises.shift.fulfill(response)
    end
  end

  class HttpResponse
    attr_reader :status, :headers, :body

    def initialize(status, headers, body)
      @status = status
      @headers = headers
      @body = body
    end
  end
end
