require 'slop'
require 'sym'
require 'colored2'
require 'yaml'
require 'forwardable'
require 'openssl'
require 'sym/application'
require 'sym/errors'
require 'sym/app/commands'
require 'sym/app/keychain'
require 'sym/app/private_key/handler'
require 'highline'

require_relative 'output/file'
require_relative 'output/file'
require_relative 'output/stdout'

module Sym
  module App
    # This is the main interface class for the CLI application.
    # It is responsible for parsing user's input, providing help, examples,
    # coordination of various sub-systems (such as PrivateKey detection), etc.
    #
    # Besides holding the majority of the application state, it contains
    # two primary public methods: +#new+ and +#run+.
    #
    # The constructor is responsible for parsing the flags and determining
    # the the application is about to do. It sets up input/output, but doesn't
    # really execute any encryption or decryption. This happens in the +#run+
    # method called immediately after +#new+.
    #
    # {{Shh::App::CLI}} module effectively performs the translation of
    # the +opts+ object (of type {Slop::Result}) and interpretation of
    # users intentions. It holds on to +opts+ for the duration of the program.
    #
    # == Responsibility Delegated
    #
    # The responsibility of determining the private key from various
    # options provided is performed by the {Sym::App::PrivateKey::Handler}
    # instance. See there for more details.
    #
    # Subsequently, +#run+ method handles the finding of the appropriate
    # {Sym::App::Commands::BaseCommand} subclass to respond to user's request.
    # Command registry, sorting, command dependencies, and finding them is
    # done by the {Sym::App::Coommands} module.
    #
    # User input is handled by the {Sym::App::Input::Handler} instance, while
    # the output is provided by the procs in the {Sym::App::Output} classes.
    #
    # Finally, the Mac OS-X -specific usage of the KeyChain, is encapsulated
    # in a cross-platform way inside the {Sym::App::Keychain} module.

    class CLI

      extend Forwardable

      def_delegators :@application, :command

      attr_accessor :opts, :application, :outputs, :output_proc

      def initialize(argv)
        begin
          argv_copy = argv.dup
          dict      = false
          if argv_copy.include?('--dictionary')
            dict = true
            argv_copy.delete('--dictionary')
          end
          self.opts = parse(argv_copy)
          if dict
            options = opts.parser.unused_options + opts.parser.used_options
            puts options.map { |o| o.to_s.gsub(/.*(--[\w-]+).*/, '\1') }.sort.join(' ')
            exit 0
          end
        rescue StandardError => e
          error exception: e
          return
        end

        configure_color(argv)

        self.application = ::Sym::Application.new(opts)
        select_output_stream
      end

      def execute
        return Sym::App.exit_code if Sym::App.exit_code != 0

        result = application.execute
        if result.is_a?(Hash)
          self.output_proc = ::Sym::App::Args.new({}).output_class
          error(result)
        else
          self.output_proc.call(result)
        end
      end

      private

      def error(hash)
        Sym::App.error(hash.merge(config: (opts ? opts.to_hash : {})))
      end

      def select_output_stream
        output_klass = application.args.output_class

        unless output_klass && output_klass.is_a?(Class)
          raise "Can not determine output class from arguments #{opts.to_hash}"
        end

        self.output_proc = output_klass.new(self).output_proc
      end

      def configure_color(argv)
        if opts[:no_color]
          Colored2.disable! # reparse options without the colors to create new help msg
          self.opts = parse(argv.dup)
        end
      end

      def parse(arguments)
        Slop.parse(arguments) do |o|
          o.banner = "Sym (#{Sym::VERSION}) – encrypt/decrypt data with a private key\n".bold.white
          o.separator 'Usage:'.yellow
          o.separator '   # Generate a new key:'.dark
          o.separator '   sym -g '.green.bold + '[ -p ] [ -x keychain ] [ -o keyfile | -q | ]  '.green
          o.separator ''
          o.separator '   # Encrypt/Decrypt '.dark
          o.separator '   sym [ -d | -e ] '.green.bold + '[ -f <file> | -s <string> ] '.green
          o.separator '        [ -k key | -K keyfile | -x keychain | -i ] '.green
          o.separator '        [ -o <output file> ] '.green
          o.separator ' '
          o.separator '   # Edit an encrypted file in $EDITOR '.dark
          o.separator '   sym -t -f <file> [ -b ]'.green.bold + '[ -k key | -K keyfile | -x keychain | -i ] '.green

          o.separator ' '
          o.separator 'Modes:'.yellow

          o.bool '-e', '--encrypt', '           encrypt mode'
          o.bool '-d', '--decrypt', '           decrypt mode'
          o.bool '-t', '--edit',    '           decrypt, open an encr. file in an $EDITOR'

          o.separator ' '
          o.separator 'Create a new private key:'.yellow

          o.bool '-g', '--generate',              '           generate a new private key'
          o.bool '-p', '--password',              '           encrypt the key with a password'

          if Sym::App.is_osx?
            o.string '-x', '--keychain', '[key-name] '.blue + 'add to (or read from) the OS-X Keychain'
          end

          o.integer '-M', '--password-timeout',   '[timeout]'.blue + '  when passwords expire (in seconds)'
          o.bool    '-P', '--no-password-cache',  '           disables caching of key passwords'

          o.separator ' '
          o.separator 'Read existing private key from:'.yellow
          o.bool      '-i', '--interactive',      '           Paste or type the key interactively'
          o.string    '-k', '--private-key',      '[key]   '.blue + '   private key as a string'
          o.string    '-K', '--keyfile',          '[key-file]'.blue + ' private key from a file'
          o.separator ' '
          o.separator 'Data to Encrypt/Decrypt:'.yellow
          o.string    '-s', '--string',           '[string]'.blue + '   specify a string to encrypt/decrypt'
          o.string    '-f', '--file',             '[file]  '.blue + '   filename to read from'
          o.string    '-o', '--output',           '[file]  '.blue + '   filename to write to'
          o.separator ' '
          o.separator 'Flags:'.yellow
          o.bool      '-b', '--backup',           '           create a backup file in the edit mode'
          o.bool      '-v', '--verbose',          '           show additional information'
          o.bool      '-T', '--trace',            '           print a backtrace of any errors'
          o.bool      '-D', '--debug',            '           print debugging information'
          o.bool      '-q', '--quiet',            '           silence all output'
          o.bool      '-V', '--version',          '           print library version'
          o.bool      '-N', '--no-color',         '           disable color output'
          o.separator ' '
          o.separator 'Utility:'.yellow
          o.string    '-a', '--bash-completion',  '[file]'.blue + '     append shell completion to a file'
          o.separator ' '
          o.separator 'Help & Examples:'.yellow
          o.bool      '-E', '--examples',         '           show several examples'
          o.bool      '-h', '--help',             '           show help'

        end
      end
    end
  end
end