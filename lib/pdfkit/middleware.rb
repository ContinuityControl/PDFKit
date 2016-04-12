class PDFKit
  class Middleware
    def initialize(app, options = {}, conditions = {})
      @app        = app
      @options    = options
      @conditions = conditions
      @render_pdf = false
      @caching    = @conditions.delete(:caching) { false }
    end

    def call(env)
      dup._call(env)
    end

    def _call(env)
      @request    = Rack::Request.new(env)
      @render_pdf = false

      set_request_to_render_as_pdf(env) if render_as_pdf?
      status, headers, response = @app.call(env)
      headers['X-cc-debug-request-path'] = @request.path
      # WEBrick trys to split the values of headers. nil and false don't like being split.
      # Neither would you, mind you, so make sure it's a string!
      headers['X-cc-debug-request-path-ends-in-pdf'] = (!!@request.path.match(%r{\.pdf$})).to_s
      headers['X-cc-debug-rendering-pdf'] = rendering_pdf?.to_s  # aka @render_pdf

      if rendering_pdf? && headers['Content-Type'] =~ /text\/html|application\/xhtml\+xml/
        headers['X-cc-debug-made-it-into-the-if'] = 'true'
        body = response.respond_to?(:body) ? response.body : response.join
        body = body.join if body.is_a?(Array)

        root_url = root_url(env)
        protocol = protocol(env)
        options = @options.merge(root_url: root_url, protocol: protocol)
        body = PDFKit.new(body, options).to_pdf
        response = [body]
        headers['X-cc-debug-overwrote-the-response-lvar'] = 'true'
        headers['X-cc-debug-pdfkit-save-pdf-was-true'] = headers['PDFKit-save-pdf'].to_s

        if headers['PDFKit-save-pdf']
          File.open(headers['PDFKit-save-pdf'], 'wb') { |file| file.write(body) } rescue nil
          headers.delete('PDFKit-save-pdf')
        end

        unless @caching
          # Do not cache PDFs
          headers.delete('ETag')
          headers.delete('Cache-Control')
        end

        headers['Content-Length'] = (body.respond_to?(:bytesize) ? body.bytesize : body.size).to_s
        headers['Content-Type']   = 'application/pdf'
      end

      [status, headers, response]
    end

    private

    def root_url(env)
      PDFKit.configuration.root_url || "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}/"
    end

    def protocol(env)
      env['rack.url_scheme']
    end

    def rendering_pdf?
      @render_pdf
    end

    def render_as_pdf?
      request_path = @request.path
      request_path_is_pdf = request_path.match(%r{\.pdf$})

      if request_path_is_pdf && @conditions[:only]
        conditions_as_regexp(@conditions[:only]).any? do |pattern|
          request_path =~ pattern
        end
      elsif request_path_is_pdf && @conditions[:except]
        conditions_as_regexp(@conditions[:except]).none? do |pattern|
          request_path =~ pattern
        end
      else
        request_path_is_pdf
      end
    end

    def set_request_to_render_as_pdf(env)
      @render_pdf = true

      path = @request.path.sub(%r{\.pdf$}, '')
      path = path.sub(@request.script_name, '')

      %w[PATH_INFO REQUEST_URI].each { |e| env[e] = path }

      env['HTTP_ACCEPT'] = concat(env['HTTP_ACCEPT'], Rack::Mime.mime_type('.html'))
      env['Rack-Middleware-PDFKit'] = 'true'
    end

    def concat(accepts, type)
      (accepts || '').split(',').unshift(type).compact.join(',')
    end

    def conditions_as_regexp(conditions)
      [conditions].flatten.map do |pattern|
        pattern.is_a?(Regexp) ? pattern : Regexp.new('^' + pattern)
      end
    end
  end
end
