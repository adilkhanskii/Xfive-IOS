# Real pinned Fastlane parser, synthetic credentials only; no Runner/network/Apple.
require "stringio"
require "tmpdir"
require "fileutils"
ENV["FASTLANE_SKIP_UPDATE_CHECK"] = "1"
ENV["FASTLANE_OPT_OUT_USAGE"] = "1"
require "fastlane"
require "deliver"

def capture_output
  previous = $stdout
  output = StringIO.new
  $stdout = output
  yield
  output.string
ensure
  $stdout = previous
end

def check(condition, message)
  raise message unless condition
end

email = "synthetic-review@example.invalid"
password = "synthetic-ONLY-review-secret"
ENV["X5_APP_REVIEW_EMAIL"] = email
ENV["X5_APP_REVIEW_PASSWORD"] = password
repo = File.expand_path("..", __dir__)

# Verify the baseline with the actual dependency, not just a source hypothesis.
# Its raw DSL table renders a Hash cell empty; the Runner Summary exposes email
# but masks the password. Capture both without emitting synthetic login values.
Dir.mktmpdir("x5-review-parser-") do |directory|
  File.write(File.join(directory, "Deliverfile"), "app_review_information({demo_user: '#{email}', demo_password: '#{password}'})\n")
  Dir.chdir(directory) do
    unsafe = FastlaneCore::Configuration.create(Deliver::Options.available_options, {})
    emitted = capture_output do
      unsafe.load_configuration_file("Deliverfile")
      FastlaneCore::PrintTable.print_values(config: unsafe,
        mask_keys: ["app_review_information.demo_password"], title: "Baseline Runner Summary")
    end
    # Terminal::Table may wrap a value or split a word across column borders.
    normalized = emitted.gsub(/\e\[[0-9;]*m/, "").gsub(/[\s|]/, "")
    check(normalized.include?(email), "Baseline username disclosure was not reproduced")
    check(!normalized.include?(password), "Pinned Fastlane baseline password masking regressed")
  end
end

Dir.chdir(repo) do
  configured = FastlaneCore::Configuration.create(Deliver::Options.available_options, {})
  emitted = capture_output do
    configured.load_configuration_file("Deliverfile")
    FastlaneCore::PrintTable.print_values(config: configured,
      mask_keys: ["app_review_information.demo_password"], title: "Synthetic Runner Summary")
  end
  actual = configured[:app_review_information]
  check(actual[:demo_user] == email && actual[:demo_password] == password, "Required credential pair changed")
  normalized = emitted.gsub(/\e\[[0-9;]*m/, "").gsub(/[\s|]/, "")
  check(!normalized.include?(email) && !normalized.include?(password), "Fixed configuration leaked synthetic credentials")

  ENV.delete("X5_APP_REVIEW_PASSWORD")
  rejected = false
  emitted = capture_output do
    begin
      FastlaneCore::Configuration.create(Deliver::Options.available_options, {}).load_configuration_file("Deliverfile")
    rescue StandardError => error
      rejected = error.message.include?("Missing protected X5 App Review credentials")
    end
  end
  check(rejected, "Missing secret did not stop configuration")
  check(!emitted.include?(email) && !emitted.include?(password), "Failure path leaked synthetic credentials")
end
puts "PASS: baseline username disclosure reproduced (password masked); protected config preserves both without stdout; missing secret refused. No Apple request."
