# frozen-string-literal: true

require "tempfile"
require "httpx"
require "down/backend"

if RUBY_VERSION < "2.5"
  require "webrick/httpstatus"
else
  require "net/http/status"
end


module Down
  class Httpx < Backend
    DEFAULT_CLIENT = HTTPX.plugins(:basic_authentication, :follow_redirects)


    STATUS_CODES = if RUBY_VERSION < "2.5"
      WEBrick::HTTPStatus::StatusMessage
    else
      Net::HTTP::STATUS_CODES
    end

    def initialize(options = {}, &block)
      @method = (options.delete(:method) || :get).to_s.downcase.to_sym
      @client = DEFAULT_CLIENT 
        .headers("user-agent" => "Down/#{Down::VERSION}")
        .max_redirects(2)
        .timeout(loop_timeout: 30)
        .with(options)
      @client = block.call(@client) if block
    end

    def download(url, max_size: nil, progress_proc: nil, content_length_proc: nil, destination: nil, max_redirects: nil, **options, &block)
      uri = URI.parse(url)
      client = @client
      client = client.max_redirects(max_redirects) if max_redirects
      client = client.plugin(response_plugin(max_size, content_length_proc, progress_proc))
      response = request(client, uri, **options, &block)

      extname  = File.extname(response.uri.path)
      tempfile = Tempfile.new(["down-http", extname], binmode: true, encoding: response.body.encoding)
      response.copy_to(tempfile)

      tempfile.open # flush written content

      tempfile.extend DownloadedFile
      tempfile.url     = response.uri.to_s
      tempfile.headers = response.headers
      tempfile.content_type = response.content_type.mime_type
      tempfile.charset = response.content_type.charset

      download_result(tempfile, destination)
    rescue URI::Error => e
      ex = InvalidUrl.new(e.message)
      ex.set_backtrace(e.backtrace)
      raise ex
    rescue
      tempfile.close! if tempfile
      raise
    end


    private

    def request(client, uri, method: @method, **options, &block)
      response = send_request(client, method, uri, **options, &block)
      begin
        response.raise_for_status
        raise Down::TooManyRedirects if (300..399).include?(response.status)
        response
      rescue => exception
        response_error!(response, exception)
      end
    end

    def send_request(client, method, uri, **options, &block)
      client = client
      client = client.basic_authentication(uri.user, uri.password) if uri.user || uri.password
      client = block.call(client) if block

      client.request(method, uri, options)
    rescue => exception
      request_error!(exception)
    end

    def response_plugin(max_size, content_length_proc, progress_proc)
      mod = Module.new do
        response_methods = Module.new do
          if content_length_proc
            const_set(:DOWN_CONTENT_LENGTH_PROC, content_length_proc)

            def initialize(*)
              super
              length = begin
                Integer(@headers["content-length"])
              rescue TypeError
                return 
              end
              self.class.const_get(:DOWN_CONTENT_LENGTH_PROC).call(length)
            end
          end

          if progress_proc
            const_set(:DOWN_PROGRESS_PROC, progress_proc)

            def <<(data)
              super
              self.class.const_get(:DOWN_PROGRESS_PROC).call(@body.bytesize)
              verify_too_large
            end
          else
            def <<(data)
              super
              verify_too_large
            end 
          end

          const_set(:DOWN_MAX_SIZE, max_size || Float::INFINITY)

          def verify_too_large
            max_size = self.class.const_get(:DOWN_MAX_SIZE)
            raise Down::TooLarge if @body.bytesize > max_size
          end
        end

        response_body_methods = Module.new do
          attr_reader :encoding
        end
        
        const_set(:ResponseMethods, response_methods)
        const_set(:ResponseBodyMethods, response_body_methods)
      end
    end

    def request_error!(exception)
      case exception
      when SocketError 
        raise Down::ConnectionError, exception.message
      when HTTPX::TimeoutError
        raise Down::TimeoutError, exception.message
      # when HTTP::Redirector::TooManyRedirectsError
      #   raise Down::TooManyRedirects, exception.message
      when OpenSSL::SSL::SSLError
        raise Down::SSLError, exception.message
      else
        raise exception
      end
    end

    def response_error!(response, exception)
      case exception
      when HTTPX::HTTPError
        status_error = "#{response.status} #{STATUS_CODES[response.status]}"
        args = [status_error, response: response]

        case response.status
        when 400..499 then raise Down::ClientError.new(*args)
        when 500..599 then raise Down::ServerError.new(*args)
        else               raise Down::ResponseError.new(*args)
        end
      else
        request_error!(exception)
      end
    end


    module DownloadedFile
      attr_accessor :url, :headers, :content_type, :charset

      def original_filename
        content_disposition = headers["content-disposition"]
        original = Utils.filename_from_content_disposition(CGI.unescape(content_disposition)) if content_disposition
        original || Utils.filename_from_path(CGI.unescape(URI.parse(url).path || ""))
      end

      def to_s
        read.to_s
      end
    end 
  end
end