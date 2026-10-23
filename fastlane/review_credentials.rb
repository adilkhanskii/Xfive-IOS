# Preserve Apple's required demo login without plaintext metadata in Git.
def required_review_credentials
  # Pinned Fastlane's Runner Summary masks the password but not the username.
  ENV["FASTLANE_SKIP_ALL_LANE_SUMMARIES"] = "1"
  email = ENV["X5_APP_REVIEW_EMAIL"].to_s.strip
  password = ENV["X5_APP_REVIEW_PASSWORD"].to_s.strip
  if email.empty? || password.empty? || [email, password].any? { |v| v.match?(/[\r\n]/) }
    raise "Missing protected X5 App Review credentials; refusing metadata upload"
  end
  { demo_user: email, demo_password: password }
end
