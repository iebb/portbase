#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'distribute_testflight_groups'
require 'open3'

module ReleaseVersion
  CLOSED_STATES = %w[READY_FOR_SALE READY_FOR_DISTRIBUTION PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE PROCESSING_FOR_APP_STORE REPLACED_WITH_NEW_VERSION REMOVED_FROM_SALE DEVELOPER_REMOVED_FROM_SALE].freeze

  def self.parts(value)
    raise ArgumentError, "Invalid marketing version #{value.inspect}" unless value.match?(/\A\d+(?:\.\d+){1,2}\z/)

    value.split('.').map(&:to_i).fill(0, value.split('.').length...3)
  end

  def self.choose(source, store_versions, trains, override = nil)
    candidates = [parts(source)] + trains.map { |version| parts(version) }
    store_versions.each do |attributes|
      version = parts(attributes.fetch('versionString'))
      version[2] += 1 if CLOSED_STATES.include?(attributes.fetch('appStoreState'))
      candidates << version
    end
    minimum = candidates.max
    if override && !override.empty?
      requested = parts(override)
      raise ArgumentError, 'Requested marketing version is below the open version train' if (requested <=> minimum).negative?

      minimum = requested
    end
    minimum.join('.')
  end

  def self.all(client, path, params = {})
    data = []
    loop do
      response = client.get(path, params.merge('limit' => '200'))
      data.concat(response.fetch('data'))
      link = response.dig('links', 'next')
      break unless link

      uri = URI(link)
      raise 'Unexpected pagination host' unless uri.host == 'api.appstoreconnect.apple.com'

      path = uri.path.delete_prefix('/v1')
      params = URI.decode_www_form(uri.query.to_s).to_h
    end
    data
  end

  def self.run
    platform = ENV.fetch('ASC_PLATFORM')
    target_name = { 'IOS' => 'PortSQL', 'MAC_OS' => 'PortbaseMac' }.fetch(platform)
    raw, status = Open3.capture2('/usr/bin/plutil', '-convert', 'json', '-o', '-', 'PortSQL.xcodeproj/project.pbxproj')
    raise 'Could not read the Xcode project' unless status.success?

    objects = JSON.parse(raw).fetch('objects')
    target = objects.values.find { |object| object['isa'] == 'PBXNativeTarget' && object['name'] == target_name }
    configurations = objects.fetch(target.fetch('buildConfigurationList')).fetch('buildConfigurations')
    settings = configurations.map { |id| objects.fetch(id) }.find { |configuration| configuration['name'] == 'Release-CI' }.fetch('buildSettings')
    raise 'Release-CI must use automatic signing' unless settings['CODE_SIGN_STYLE'] == 'Automatic'

    client = TestFlightGroupDistributor::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key_path: ENV.fetch('ASC_KEY_PATH'))
    app_id = ENV.fetch('APP_STORE_ID')
    versions = all(client, "/apps/#{app_id}/appStoreVersions", 'filter[platform]' => platform).map { |version| version.fetch('attributes') }
    trains = all(client, "/apps/#{app_id}/preReleaseVersions").map { |train| train.fetch('attributes') }.select { |train| train.fetch('platform') == platform }.map { |train| train.fetch('version') }
    version = choose(settings.fetch('MARKETING_VERSION'), versions, trains, ENV['PORTBASE_MARKETING_VERSION'])
    # Query all existing builds, including Cloud/local builds, so moving CI or
    # rerunning a workflow never reuses an uploaded build number.
    numbers = all(client, '/builds', 'filter[app]' => app_id).map { |build| build.fetch('attributes').fetch('version') }
    numeric_numbers = numbers.select { |number| number.match?(/\A\d+\z/) }.map(&:to_i)
    raise 'Existing dotted build numbers need an explicit migration' unless numeric_numbers.length == numbers.length

    build_number = [numeric_numbers.max.to_i + 1, ENV.fetch('GITHUB_RUN_NUMBER', '1').to_i].max
    raise 'Build number exceeds the App Store limit' if build_number > 9999

    output = "CI_MARKETING_VERSION=#{version}\nCI_BUILD_NUMBER=#{build_number}\nCI_COMMIT=#{ENV.fetch('GITHUB_SHA')}\n"
    File.open(ENV.fetch('GITHUB_ENV'), 'a') { |file| file.write(output) }
    puts "#{platform}: #{version} (#{build_number}), commit #{ENV.fetch('GITHUB_SHA')}"
  end
end

ReleaseVersion.run if $PROGRAM_NAME == __FILE__
