require "yast2/systemctl"

require "ostruct"
require "forwardable"

module Yast
  ###
  #  Use this class always as a parent class for implementing various systemd units.
  #  Do not use it directly for ad-hoc implementation of systemd units.
  #
  #  @example Create a systemd service unit
  #
  #     class Service < Yast::SystemdUnit
  #       SUFFIX = ".service"
  #       PROPMAP = {
  #         before: "Before"
  #       }
  #
  #       def initialize service_name, propmap={}
  #         service_name += SUFFIX unless service_name.end_with?(SUFFIX)
  #         super(service_name, PROPMAP.merge(propmap))
  #       end
  #
  #       def before
  #         properties.before.split
  #       end
  #     end
  #
  #     service = Service.new('sshd')
  #
  #     service.before # ['shutdown.target', 'multi-user.target']
  #
  class SystemdUnit
    Yast.import "Stage"
    include Yast::Logger

    SUPPORTED_TYPES  = %w(service socket target).freeze
    SUPPORTED_STATES = %w(enabled disabled).freeze

    # A Property Map is a plain Hash(Symbol => String).
    # It
    # 1. enumerates the properties we're interested in
    # 2. maps their Ruby names (snake_case) to systemd names (CamelCase)
    class PropMap < Hash
    end

    # @return [PropMap]
    DEFAULT_PROPMAP = {
      id:              "Id",
      pid:             "MainPID",
      description:     "Description",
      load_state:      "LoadState",
      active_state:    "ActiveState",
      sub_state:       "SubState",
      unit_file_state: "UnitFileState",
      path:            "FragmentPath"
    }.freeze

    extend Forwardable

    def_delegators :@properties, :id, :path, :description, :active?, :enabled?, :loaded?

    # @return [String] eg. "apache2"
    #   (the canonical one, may be different from unit_name)
    attr_reader :name
    # @return [String] eg. "apache2"
    attr_reader :unit_name
    # @return [String] eg. "service"
    attr_reader :unit_type
    # @return [PropMap]
    attr_reader :propmap
    # @return [String]
    attr_reader :error
    # @return [Properties]
    attr_reader :properties

    # @param propmap [Hash{Symbol => String}]
    def initialize(full_unit_name, propmap = {}, property_text = nil)
      @unit_name, dot, @unit_type = full_unit_name.rpartition(".")
      raise "Missing unit type suffix" if dot.empty?

      log.warn "Unsupported unit type '#{unit_type}'" unless SUPPORTED_TYPES.include?(unit_type)
      @propmap = propmap.merge!(DEFAULT_PROPMAP)

      @properties = show(property_text)
      # eg "Failed to get properties: Unit name apache2@.service is not valid."
      @error = properties.error
      # Id is not present when the unit name is not valid
      @name = id.to_s.split(".").first || unit_name
    end

    def refresh!
      @properties = show
      @error = properties.error
      properties
    end

    # Run 'systemctl show' to read the unit properties
    # @return [Properties]
    def show(property_text = nil)
      # Using different handler during first stage (installation, update, ...)
      Stage.initial ? InstallationProperties.new(self, property_text) : Properties.new(self, property_text)
    end

    def status
      command("status", options: "2>&1").stdout
    end

    def start
      run_command! { command("start") }
    end

    def stop
      run_command! { command("stop") }
    end

    def enable
      run_command! { command("enable") }
    end

    def disable
      run_command! { command("disable") }
    end

    def restart
      run_command! { command("restart") }
    end

    def try_restart
      run_command! { command("try-restart") }
    end

    def reload
      run_command! { command("reload") }
    end

    def reload_or_restart
      run_command! { command("reload-or-restart") }
    end

    def reload_or_try_restart
      run_command! { command("reload-or-try-restart") }
    end

    # @param command_name [String]
    # @return [#command,#stdout,#stderr,#exit]
    def command(command_name, options = {})
      command = "#{command_name} #{unit_name}.#{unit_type} #{options[:options]}"
      Systemctl.execute(command)
    end

  private

    # Run a command, pass its stderr to {#error}, {#refresh!}.
    # @yieldreturn [#command,#stdout,#stderr,#exit]
    # @return [Boolean] success? (exit was zero)
    def run_command!
      error.clear
      command_result = yield
      error << command_result.stderr
      refresh!
      command_result.exit.zero?
    end

    # Structure holding  properties of systemd unit
    class Properties < OpenStruct
      include Yast::Logger

      # @param systemd_unit [SystemdUnit]
      def initialize(systemd_unit, property_text)
        super()
        self[:systemd_unit] = systemd_unit
        if property_text.nil?
          raw_output   = load_systemd_properties
          self[:raw]   = raw_output.stdout
          self[:error] = raw_output.stderr
          self[:exit]  = raw_output.exit
        else
          self[:raw]   = property_text
          self[:error] = ""
          self[:exit]  = 0
        end

        if !exit.zero? || !error.empty?
          message = "Failed to get properties for unit '#{systemd_unit.unit_name}' ; "
          message << "Command `#{raw_output.command}` returned error: #{error}"
          log.error(message)
          self[:not_found?] = true
          return
        end

        extract_properties
        self[:active?]    = active_state == "active" || active_state == "activating"
        self[:running?]   = sub_state    == "running"
        self[:loaded?]    = load_state   == "loaded"
        self[:not_found?] = load_state   == "not-found"
        self[:enabled?]   = read_enabled_state
        self[:supported?] = SUPPORTED_STATES.include?(unit_file_state)
      end

    private

      # Check the value of #unit_file_state; its value mirrors UnitFileState dbus property
      # @return [Boolean] True if enabled, False if not
      def read_enabled_state
        # If UnitFileState property is missing (due to e.g. legacy sysvinit service) or
        # has an unknown entry (e.g. "bad") we must use a different way how to get the
        # real status of the service.
        if SUPPORTED_STATES.include?(unit_file_state)
          state_name_enabled?(unit_file_state)
        else
          # Check for exit code of `systemctl is-enabled systemd_unit.name` ; additionally
          # test the stdout of the command for valid values when the service is enabled
          # http://www.freedesktop.org/software/systemd/man/systemctl.html#is-enabled%20NAME...
          status = systemd_unit.command("is-enabled")
          status.exit.zero? && state_name_enabled?(status.stdout)
        end
      end

      # Systemd service unit can have various states like enabled, enabled-runtime,
      # linked, linked-runtime, masked, masked-runtime, static, disabled, invalid.
      # We test for the return value 'enabled' and 'enabled-runtime' to consider
      # a service as enabled.
      # @return [Boolean] True if enabled, False if not
      def state_name_enabled?(state)
        ["enabled", "enabled-runtime"].include?(state.strip)
      end

      def extract_properties
        systemd_unit.propmap.each do |name, property|
          self[name] = raw[/#{property}=(.+)/, 1]
        end
      end

      def load_systemd_properties
        names = systemd_unit.propmap.values
        systemd_unit.command("show", options: "--property=" + names.join(","))
      end
    end

    # systemd command `systemctl show` is not available during installation
    # and will return error "Running in chroot, ignoring request." Therefore, we must
    # avoid calling it in the installation workflow. To keep the API partially
    # consistent, this class offers a replacement for the Properties above.
    #
    # It has two goals:
    # 1. Checks for existence of the unit based on the stderr from the command
    #    `systemctl is-enabled`
    # 2. Retrieves the status enabled|disabled which is needed in the installation
    #    system. There are currently only 3 commands available for systemd in
    #    inst-sys/chroot: `systemctl enable|disable|is-enabled`. The rest will return
    #    the error message mentioned above in this comment.
    #
    # Once the inst-sys has running dbus/systemd, this class definition can be removed
    # together with the condition for Stage.initial in the SystemdUnit#show.
    class InstallationProperties < OpenStruct
      include Yast::Logger

      def initialize(systemd_unit, _property_text)
        super()
        self[:systemd_unit] = systemd_unit
        self[:status]       = read_status
        self[:raw]          = status.stdout
        self[:error]        = status.stderr
        self[:exit]         = status.exit
        self[:enabled?]     = status.exit.zero?
        self[:not_found?]   = service_missing?
      end

    private

      def read_status
        systemd_unit.command("is-enabled")
      end

      # Analyze the exit code and stdout of the command `systemctl is-enabled service_name`
      # http://www.freedesktop.org/software/systemd/man/systemctl.html#is-enabled%20NAME...
      def service_missing?
        # the service exists and it's enabled
        return false if status.exit.zero?
        # the service exists and it's disabled
        return false if status.exit.nonzero? && status.stdout.match(/disabled|masked|linked/)
        # for all other cases the service does not exist
        true
      end
    end
  end
end
