require 'octokit'
require 'pp'
require 'faraday'
require 'openssl'
require 'uri'
require 'json'

def with_config
  config_file = File.dirname(File.expand_path(__FILE__)) + '/../config/indico.yaml'
  config_data = YAML::load(File.open(config_file))

  yield config_data
end

def each_repo(widget_name)
  with_config do |config_data|
    octo_client = Octokit::Client.new(:access_token => config_data['auth_token'])

    config_data['widgets'][widget_name].each do |repo|
      yield config_data, octo_client, repo
    end
  end
end

def plural(text, n)
  n > 1 ? text + "s" : text
end

def humanize_delta(seconds)
  minutes = seconds.to_i / 60
  if minutes > 0
    hours = minutes / 60
    if hours > 0
      days = hours / 24
      if days > 0
        weeks = days / 7
        if weeks > 0
          plural "#{weeks} week", weeks
        else
          plural "#{days} day", days
        end
      else
        plural "#{hours} hour", hours
      end
    else
      plural "#{minutes} minute", minutes
    end
  else
    plural "#{seconds} second", seconds
  end
end


SCHEDULER.every '15m', :first_in => '1s' do |job|
  each_repo('pull_requests') do |config, client, repo|
    open_prs = client.pull_requests(repo['path'], :state => 'open').map do |pull|
      {
        title: pull.title,
        updated_at: pull.updated_at.strftime("%b %-d %Y, %l:%m %p"),
        creator: "@" + pull.user.login,
      }
    end

    send_event(repo['target_elem'], { header: "<strong>#{open_prs.length}</strong> Open Pull Requests", pulls: open_prs[0..10] })
  end
end


SCHEDULER.every '15m', :first_in => '1s' do |job|
  each_repo('branches') do |config, client, repo|
    branches = client.branches(repo['path'])

    heads = branches.map do |branch|
      commit = client.commit(repo['path'], branch.commit.sha)
      {
        :name => branch.name,
        :commit => commit.sha,
        :date => humanize_delta(Time.now - commit.commit.committer.date),
        :author => commit.commit.author.name,
        :avatar => commit.author ? commit.author.avatar_url : nil,
        :timestamp => commit.commit.committer.date.to_i
      }
    end.sort_by { |elem| elem[:timestamp] }.reverse

    send_event(repo['target_elem'], { repo_name: repo['title'], heads: heads })
  end

end


SCHEDULER.every '15m', :first_in => '1s' do |job|
  each_repo('team_repos') do |config, client, repo|

    heads = []

    config['team_members'].each do |member|
      repo_path = "#{member['username']}/#{repo['name']}"
      user = client.user(member['username'])

      begin
        client.branches(repo_path).map do |branch|

          commit = client.commit(repo_path, branch.commit.sha)
          heads.push({
            :repo_path => repo_path,
            :repo_owner => user.name,
            :repo_owner_avatar => user.avatar_url,
            :name => branch.name,
            :commit => commit.sha,
            :date => humanize_delta(Time.now - commit.commit.committer.date),
            :author => commit.commit.author.name,
            :avatar => commit.author ? commit.author.avatar_url : nil,
            :timestamp => commit.commit.committer.date.to_i
          })
        end
      rescue Octokit::NotFound
        puts "ERR: #{repo_path}"
      end
    end

    send_event(repo['target_elem'], { repo_name: repo['title'],
      heads: heads.sort_by { |elem| elem[:timestamp] }.reverse })
  end
end

def indico_api_call(res_path, params, config)
    path = "/export/#{res_path}"

    params.merge!({
      :ak => config['indico']['api_key'],
      :timestamp => Time.now.to_i
    })

    conn = Faraday.new(:url => 'https://indico.cern.ch/export') do |faraday|
      faraday.request  :url_encoded             # form-encode POST params
#      faraday.response :logger                  # log requests to STDOUT
      faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
    end

    qstring = URI.encode_www_form(params.map { |k,v| [k, v] }.sort_by { |t| t[0] })
    url = "#{path}?#{qstring}"

    signature = OpenSSL::HMAC.hexdigest(
      OpenSSL::Digest.new('sha1'), config['indico']['secret'], url)

    params[:signature] = signature.to_s

    response = conn.get res_path, params
    yield response.status, response.body
end

SCHEDULER.every '15m', :first_in => '1s' do |job|

  with_config do |config|

    team_members = Hash[config['team_members'].map {
      |member| [member['name'], member['username']]}]
    meetings = []

    indico_api_call('categ/3717.json', {}, config) do |status, body|
      if status == 200
        data = JSON.parse(body)
        meetings = data['results'].map do |entry|
          {
            :timestamp => DateTime.parse("#{entry['startDate']['date']} #{entry['startDate']['time']}"),
            :title => entry["title"],
            :id => entry["id"]
          }
        end.select { |e| e[:timestamp] > DateTime.now }
      else
        puts "#{response.status}: #{response.body}"
      end
    end

    if meetings.length > 0
      next_meeting = meetings[-1]

      indico_api_call(
        "event/#{next_meeting[:id]}.json", {:detail => 'contributions'}, config) do |status, body|
        if status == 200
          data = JSON.parse(body)

          written = data['results'][0]['contributions'].map do |contrib|
            username = team_members[contrib["title"]]
            if username and !contrib['material'].empty?
              username
            end
          end.select { |e| !  e.nil? }.to_set

          written = Hash[team_members.map do |k, v|
            [v, {
              :written => written.include?(v),
              :avatar => "https://avatars.githubusercontent.com/" + v
            }]
          end]

          send_event('indico-meeting', {
           exists: true,
           meeting_title: next_meeting[:title],
           timestamp: next_meeting[:timestamp].strftime("%a %e %b"),
           written: written
          })
        else
          puts "#{response.status}: #{response.body}"
        end
      end
    else
      send_event('indico-meeting', { exists: false })
    end
  end

end