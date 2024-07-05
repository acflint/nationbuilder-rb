class NationBuilder::Client
  def initialize(nation_name, api_key, opts = {})
    @nation_name = nation_name
    @api_key = api_key
    @name_to_endpoint = {}
    @base_url = opts[:base_url] || "https://:nation_name.nationbuilder.com"
    @retries = opts[:retries] || 8
    @http_client = opts[:http_client] || HTTPClient.new


    raise 'Retries must be at least zero' if @retries < 0

    parsed_endpoints.each do |endpoint|
      @name_to_endpoint[endpoint.name] = endpoint
    end
  end

  def parsed_endpoints
    NationBuilder::SpecParser
      .parse(File.join(File.dirname(__FILE__), "..", "api_spec/spec.json"))
  end

  class InvalidEndpoint < ArgumentError; end

  def [](endpoint)
    e = @name_to_endpoint[endpoint]
    raise InvalidEndpoint, endpoint if e.nil?

    e
  end

  def endpoints
    @name_to_endpoint.keys
  end

  def base_url
    @base_url.gsub(":nation_name", @nation_name)
  end

  RETRY_DELAY = 0.1 # seconds

  def raw_call(path, method, body = {}, args = {})
    url = NationBuilder::URL.new(base_url).generate_url(path, args)

    request_args = {
      header: {
        "Accept" => "application/json",
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}"
      },
      query: {}
    }

    if method == :get
      request_args[:query].merge!(NationBuilder::Utils::QueryParams.encode(body))
    else
      body[:access_token] = @api_key
      request_args[:query][:fire_webhooks] = body[:fire_webhooks] unless body[:fire_webhooks].nil?
      request_args[:body] = JSON(body)
    end

    perform_request_with_retries(method, url, request_args)
  end

  def call(endpoint_name, method_name, args = {})
    endpoint = self[endpoint_name]
    method = endpoint[method_name]
    nonmethod_args = method.nonmethod_args(args)
    method_args = method.method_args(args)
    method.validate_args(method_args)
    raw_call(method.uri, method.http_method, nonmethod_args, args)
  end

  def perform_request_with_retries(method, url, request_args)
    parsed_response = nil
    exception_to_reraise = nil

    (@retries + 1).times do |i|
      set_response(@http_client.send(method, url, request_args))
      parsed_response = parse_response_body(response)
    rescue NationBuilder::RateLimitedError => e
      exception_to_reraise = e
      retry_after_header = response.header["Retry-After"]&.first&.to_i
      retry_after = retry_after_header&.positive? ? retry_after_header : RETRY_DELAY * 2**i
      Kernel.sleep(retry_after)
      retry
    else
      exception_to_reraise = nil
      break
    end

    # If the retry cycle ended with an error, reraise it
    raise exception_to_reraise if exception_to_reraise

    parsed_response
  end

  def set_response(value)
    Thread.current[:nationbuilder_rb_response] = value
  end

  # This getter is used for fetching the raw response
  def response
    Thread.current[:nationbuilder_rb_response]
  end

  def classify_response_error(response)
    if response.code == 429
      NationBuilder::RateLimitedError.new(response.body)
    elsif response.code.to_s.start_with?("4")
      NationBuilder::ClientError.new(response.body)
    elsif response.code.to_s.start_with?("5")
      NationBuilder::ServerError.new(response.body)
    end
  end

  def parse_response_body(response)
    error = classify_response_error(response)
    raise error if error

    content_type = response.header["Content-Type"].first
    unless content_type && content_type.include?("application/json")
      return true
    end

    parsed_body(response.body)
  end

  def print_all_descriptions
    endpoints.each do |endpoint_name|
      print_description(endpoint_name)
      puts
    end
  end

  def print_description(endpoint_name)
    endpoint_name = endpoint_name.to_sym

    unless endpoints.include?(endpoint_name)
      puts "Invalid endpoint name: #{endpoint_name}"
      puts "Valid endpoint names:"

      endpoints.each do |endpoint|
        puts "  #{endpoint}"
      end
      return
    end

    endpoint_str = "Endpoint: #{endpoint_name}"
    puts '=' * endpoint_str.length
    puts endpoint_str
    puts '=' * endpoint_str.length

    self[endpoint_name].methods.each do |method_name|
      puts
      method = self[endpoint_name][method_name]
      puts "  Method: #{method_name}"
      puts "  Description: #{method.description}"
      required_params = method.parameters.map { |p| p }

      puts "  Required parameters: #{required_params.join(', ')}" if required_params.any?
    end
  end

  private

  def parsed_body(body)
    if body.empty?
      {}
    else
      JSON.parse(body)
    end
  end
end
