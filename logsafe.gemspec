# frozen_string_literal: true

require_relative "lib/logsafe/version"

Gem::Specification.new do |spec|
  spec.name = "logsafe"
  spec.version = Logsafe::VERSION
  spec.authors = ["tin.trung.duong"]
  spec.email = ["tin@costtracker.no"]

  spec.summary = "One sorted log file per day in your own bucket, with a page to search them on."
  spec.description = "Keep your Docker containers' logs in S3, Google Cloud Storage or a folder, without paying " \
                     "for hosted logging. Vector ships the lines, a background job on any Active Job backend " \
                     "merges each day into one sorted, compressed file, and a page you mount in your app " \
                     "searches them. Lines can be encrypted before they leave the server."
  spec.homepage = "https://github.com/TTD93/LogSafe"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/v#{spec.version}/README.md"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true" # nobody publishes a version without a second factor

  # The files that are in git, without the ones only this repository needs. shipper/ is part of the gem:
  # how it writes the lines, and encrypts them, has to fit the version that reads them.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile Rakefile .gitignore .rspec spec/ .github/ .rubocop.yml shipper/test])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1"
end
