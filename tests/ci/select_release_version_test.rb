# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../../scripts/select-release-version'

class ReleaseVersionTest < Minitest::Test
  def test_closed_train_advances_and_preserves_higher_testflight_train
    versions = [{ 'versionString' => '1.5.0', 'appStoreState' => 'READY_FOR_SALE' }]
    assert_equal '1.5.1', ReleaseVersion.choose('1.5.0', versions, ['1.5.1'])
    assert_equal '1.6.0', ReleaseVersion.choose('1.5.0', versions, ['1.6.0'])
  end

  def test_in_review_build_does_not_force_a_new_train_or_wait
    versions = [{ 'versionString' => '1.6.0', 'appStoreState' => 'WAITING_FOR_REVIEW' }]
    assert_equal '1.6.0', ReleaseVersion.choose('1.6.0', versions, ['1.6.0'])
  end

  def test_pending_release_is_closed_and_initial_mac_draft_is_open
    assert_equal '1.6.1', ReleaseVersion.choose('1.6.0', [{ 'versionString' => '1.6.0', 'appStoreState' => 'PENDING_DEVELOPER_RELEASE' }], [])
    assert_equal '1.6.0', ReleaseVersion.choose('1.6.0', [{ 'versionString' => '1.6.0', 'appStoreState' => 'PREPARE_FOR_SUBMISSION' }], [])
  end

  def test_override_cannot_downgrade_and_two_part_versions_compare_correctly
    assert_equal '1.6.0', ReleaseVersion.choose('1.5.0', [], ['1.6'])
    assert_raises(ArgumentError) { ReleaseVersion.choose('1.6.0', [], [], '1.5.9') }
    assert_raises(ArgumentError) { ReleaseVersion.choose('1.6.0-beta', [], []) }
  end

  def test_follows_all_pages
    calls = []
    client = Object.new
    client.define_singleton_method(:get) do |path, params|
      calls << [path, params]
      if calls.length == 1
        { 'data' => [1], 'links' => { 'next' => 'https://api.appstoreconnect.apple.com/v1/builds?cursor=next' } }
      else
        { 'data' => [2] }
      end
    end
    assert_equal [1, 2], ReleaseVersion.all(client, '/builds', 'filter[app]' => 'app')
    assert_equal 'next', calls.last[1]['cursor']
  end
end
