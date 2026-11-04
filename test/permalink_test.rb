# frozen_string_literal: true

require "test_helper"

class PermalinkTest < Minitest::Test
  def test_extracts_slack_wrapped_link
    text = "see <https://sixfifty.slack.com/archives/C0123ABC/p1730700000123456|link>"
    assert_equal [{ channel: "C0123ABC", ts: "1730700000.123456", thread_ts: nil }],
                 Conclave::Permalink.extract(text)
  end

  def test_extracts_thread_ts_from_query
    text = "<https://sixfifty.slack.com/archives/C0123ABC/p1730700000123456" \
           "?thread_ts=1730690000.000100&cid=C0123ABC>"
    assert_equal [{ channel: "C0123ABC", ts: "1730700000.123456", thread_ts: "1730690000.000100" }],
                 Conclave::Permalink.extract(text)
  end

  def test_extracts_private_channel_and_bare_url
    text = "https://sixfifty.slack.com/archives/G99XYZ/p1730700000123456"
    assert_equal "G99XYZ", Conclave::Permalink.extract(text).first[:channel]
  end

  def test_extracts_multiple
    text = "a https://x.slack.com/archives/C1/p1730700000123456 b https://x.slack.com/archives/C2/p1730700000654321"
    channels = Conclave::Permalink.extract(text).map { |link| link[:channel] }
    assert_equal %w[C1 C2], channels
  end

  def test_ignores_non_slack_urls
    assert_empty Conclave::Permalink.extract("https://example.com/archives/C0123ABC/p1730700000123456")
    assert_empty Conclave::Permalink.extract("https://evil.com/?u=https://x.slack.com.evil.com/archives/C1/p1730700000123456")
  end

  def test_ignores_malformed_ts
    assert_empty Conclave::Permalink.extract("https://sixfifty.slack.com/archives/C0123ABC/p12345")
  end
end
