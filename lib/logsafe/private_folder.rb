# frozen_string_literal: true

module Logsafe
  # A folder for this user alone, and not taken over from anyone else. The same one for every process
  # of this user, or, when someone else was first to take that name, one for this process.
  module PrivateFolder
    class << self
      def path(name)
        usual = File.join(Dir.tmpdir, "#{name}-#{Process.uid}")
        Dir.mkdir(usual, 0o700)
        usual
      rescue Errno::EEXIST
        private?(usual) ? usual : own(name)
      end

      private

      def private?(dir)
        found = File.lstat(dir)
        found.directory? && found.owned? && (found.mode & 0o077).zero?
      end

      def own(name)
        @own = nil unless @own && File.directory?(@own)
        @own ||= Dir.mktmpdir("#{name}-")
      end
    end
  end
end
