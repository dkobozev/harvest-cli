#!/usr/bin/env ruby

#
# Command line client for Harvest.
#

#encoding: UTF-8

require 'base64'
require 'net/http'
require 'net/https'
require 'time'
require 'json'
require 'pathname'

# external dependencies
require 'inifile'


class HarvestClient

  def initialize(subdomain, email, password, has_ssl = true)
    @subdomain = subdomain
    @email     = email
    @password  = password

    # Business accounts have ssl support enabled. Set this to false if your
    # WEB UI is accessible via http:// instead of https://. Note that
    # Harvest will redirect you to the proper protocol regardless of
    # this. You just need to handle the redirection pragmatically. This
    # sample does this, your implementation should save the last known
    # protocol to avoid increased latency.
    @preferred_protocols = [has_ssl, !has_ssl]
  end

  def headers
    {
      "Accept"        => "application/json",
      # promise to send XML
      "Content-Type"  => "application/json; charset=utf-8",

      # All requests will be authenticated using HTTP Basic Auth, as
      # described in rfc2617. Your library probably has support for
      # basic_auth built in, I've passed the Authorization header
      # explicitly here only to show what happens at HTTP level.
      "Authorization" => "Basic #{auth_string}",
      "User-Agent"    => "Harvest CLI",
    }
  end

  def auth_string
    Base64.encode64("#{@email}:#{@password}").delete("\r\n")
  end

  def request(path, method = :get, body = "")
    response = send_request(path, method, body)
    if response.class < Net::HTTPSuccess
      # response in the 2xx range
      on_completed_request
      return response
    elsif response.class == Net::HTTPServiceUnavailable
      # response status is 503, you have reached the API throttle
      # limit. Harvest will send the "Retry-After" header to indicate
      # the number of seconds your boot needs to be silent.
      raise "Got HTTP 503 three times in a row" if retry_counter > 3
      sleep(response['Retry-After'].to_i + 5)
      request(path, method, body)
    elsif response.class == Net::HTTPFound
      # response was a redirect, most likely due to protocol
      # mismatch. Retry again with a different protocol.
      @preferred_protocols.shift
      raise "Failed connection using http or https" if @preferred_protocols.empty?
      connect!
      request(path, method, body)
    else
      dump_headers = response.to_hash.map { |h,v| [h.upcase,v].join(': ') }.join("\n")
      raise "#{response.message} (#{response.code})\n\n#{dump_headers}\n\n#{response.body}\n"
    end
  end

  def connect!
    port = has_ssl ? 443 : 80
    @connection             = Net::HTTP.new("#{@subdomain}.harvestapp.com", port)
    @connection.use_ssl     = has_ssl
    @connection.verify_mode = OpenSSL::SSL::VERIFY_NONE if has_ssl
  end

  private

  def has_ssl
    @preferred_protocols.first
  end

  def send_request(path, method = :get, body = '')
    case method
    when :get
      @connection.get(path, headers)
    when :post
      @connection.post(path, body, headers)
    when :put
      @connection.put(path, body, headers)
    when :delete
      @connection.delete(path, headers)
    end
  end

  def on_completed_request
    @retry_counter = 0
  end

  def retry_counter
    @retry_counter ||= 0
    @retry_counter += 1
  end
end


class Harvest

    def initialize
        config = read_config

        login = config['Login']
        domain, email, password = login['domain'], login['email'], login['password']

        if !domain
            puts 'Error: no domain specified in config file'
            exit(1)
        elsif !email
            puts 'Error: no email specified in config file'
            exit(1)
        elsif !password
            puts 'Error: no password specified in config file'
            exit(1)
        end

        project = config['Project']
        @project_id = project['project_id']
        @task_id    = project['task_id']

        if !@project_id
            puts 'Error: no project id specified in config file'
            exit(1)
        elsif !@task_id
            puts 'Error: no task id specified in config file'
            exit(1)
        end

        @client = HarvestClient.new(domain, email, password)
        @client.connect!
    end

    def entries
        response = @client.request '/daily', :get
        data = JSON.parse(response.body)
        data['day_entries'].select do |e|
            e['project_id'] == @project_id && e['task_id'] == @task_id
        end
    end

    def create_entry(hours, options = {})
        request = {
            :project_id => @project_id,
            :task_id    => @task_id,
            :hours      => hours,
            :notes      => options[:notes],
            :spent_at   => Time.now,
        }
        response = @client.request '/daily/add', :post, JSON.unparse(request)
        JSON.parse(response.body)
    end

    def update_entry(hours, options = {})
        request = {
            :project_id => @project_id,
            :task_id    => @task_id,
            :hours      => hours,
            :notes      => options[:notes],
            :spent_at   => Time.now,
        }
        response = @client.request "/daily/update/#{options[:id]}", :post, JSON.unparse(request)
        JSON.parse(response.body)
    end

    def log_hours(hours, options = {})
        if entry = entries.first
            options[:id] = entry['id']
            update_entry(entry['hours'].to_f + hours, options)
        else
            create_entry(hours, options)
        end
    end

    def show_first
        format_entry(entries.first)
    end

    def format_entry(entry)
        puts entry['project']
        puts entry['task']
        puts entry['hours'].to_s + ' hours'
        puts entry['notes']
    end

    def cmd(argv)
        if argv.size < 1
            puts "Error: missing command; don't know what to do, quitting..."
            exit(1)
        end

        case argv[0]
        when 'log'
            hours, notes = argv[1..-1]
            log_hours(hours.to_f, :notes => notes)
            show_first
        when 'show'
            show_first
        else
            puts "Error: unknown command '#{argv[0]}', quitting..."
            exit(1)
        end
    end

    def read_config
        user_config = IniFile.new(File.expand_path('~/.harvest'))
        config = user_config.to_h

        project_config = IniFile.new(find_config(Pathname.new(Dir.pwd)))
        config.merge! project_config.to_h
    end

    def find_config(pathname)
        config = pathname.join('.harvest')
        if config.exist?
            config
        elsif !pathname.parent.root? && !pathname.parent.symlink?
            find_config(pathname.parent)
        end
    end
end


if __FILE__ == $0
    harvest = Harvest.new
    harvest.cmd(ARGV)
end
