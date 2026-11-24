# frozen_string_literal: true

require_relative "lib/logsafe/version"

Gem::Specification.new do |spec|
  spec.name = "logsafe"
  spec.version = Logsafe::VERSION
  spec.authors = ["tin.trung.duong"]
  spec.email = ["tin@costtracker.no"]

  spec.summary = "One sorted log file per day in your own bucket, merged by a background job."
  spec.description = "A log shipper puts your containers' logs in S3, Google Cloud Storage or a folder. " \
                     "This job, run by Solid Queue, Sidekiq or any other Active Job backend, turns them " \
                     "into one sorted file per day. A cheap alternative to hosted logging."
  spec.homepage = "https://github.com/TTD93/LogSafe"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml shipper/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
