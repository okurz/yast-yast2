# ***************************************************************************
#
# Copyright (c) 2002 - 2012 Novell, Inc.
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail,
# you may find current contact information at www.novell.com
#
# ***************************************************************************
# File:  modules/WorkflowManager.rb
# Package:  yast2
# Summary:  Provides API for configuring workflows
# Authors:  Lukas Ocilka <locilka@suse.cz>
#
# Provides API for managing and configuring installation and
# configuration workflow.
#
# Module was created as a solution for
# FATE #129: Framework for pattern based Installation/Deployment
#
# Module unifies Add-Ons and Patterns modifying the workflow.
#
require "yast"
require "yast2/control_log_dir_rotator"

require "packages/package_downloader"
require "packages/package_extractor"

module Yast
  class WorkflowManagerClass < Module
    include Yast::Logger

    def main
      Yast.import "UI"
      Yast.import "Pkg"

      textdomain "base"

      Yast.import "ProductControl"
      Yast.import "ProductFeatures"

      Yast.import "Label"
      Yast.import "Wizard"
      Yast.import "Directory"
      Yast.import "FileUtils"
      Yast.import "Stage"
      Yast.import "String"
      Yast.import "XML"
      Yast.import "Report"

      #
      #    This API uses some new terms that need to be explained:
      #
      #    * Workflow Store
      #      - Kind of database of installation or configuration workflows
      #
      #    * Base Workflow
      #      - The initial workflow defined by the base product
      #      - In case of running system, this will be probably empty
      #
      #    * Additional Workflow
      #      - Any workflow defined by Add-On or Pattern in installation
      #        or Pattern in running system
      #
      #    * Final Workflow
      #      - Workflow that contains the base workflow modified by all
      #        additional workflows
      #

      # Base Workflow Store
      @wkf_initial_workflows = []
      @wkf_initial_proposals = []
      @wkf_initial_inst_finish = []
      @wkf_initial_clone_modules = []
      @wkf_initial_system_roles = []

      @wkf_initial_product_features = {}

      # Additional inst_finish settings defined by additional control files.
      # They are always empty at the begining.
      @additional_finish_steps_before_chroot = []
      @additional_finish_steps_after_chroot = []
      @additional_finish_steps_before_umount = []

      # FATE #305578: Add-On Product Requiring Registration
      # $[ "workflow filename" : (boolean) require_registration ]
      @workflows_requiring_registration = []

      @workflows_to_sources = {}

      @base_workflow_stored = false

      # Contains all currently workflows added to the Workflow Store
      @used_workflows = []

      # Some workflow changes need merging
      @unmerged_changes = false

      # Have system proposals already been prepared for merging?
      @system_proposals_prepared = false

      # Have system workflows already been prepared for merging?
      @system_workflows_prepared = false

      @control_files_dir = "additional-control-files"

      # Merge counter used for logging
      @merge_counter = 0

      # base product that got its workflow merged
      # @see #merge_product_workflow
      self.merged_base_product = nil

      self.merged_modules_extensions = []
    end

    # Returns list of additional inst_finish steps requested by
    # additional workflows.
    #
    # @param [String] which_steps (type) of finish ("before_chroot", "after_chroot" or "before_umount")
    # @return [Array<String>] steps to be called ...see which_steps parameter
    def GetAdditionalFinishSteps(which_steps)
      ret = case which_steps
      when "before_chroot"
        @additional_finish_steps_before_chroot
      when "after_chroot"
        @additional_finish_steps_after_chroot
      when "before_umount"
        @additional_finish_steps_before_umount
      else
        Builtins.y2error("Unknown FinishSteps type: %1", which_steps)
        nil
      end

      deep_copy(ret)
    end

    # Stores the current ProductControl settings as the initial settings.
    # These settings are: workflows, proposals, inst_finish, and clone_modules.
    #
    # @param [Boolean] force storing even if it was already stored, in most cases, it should be 'false'
    def SetBaseWorkflow(force)
      if @base_workflow_stored && !force
        Builtins.y2milestone("Base Workflow has been already set")
        return
      end

      @wkf_initial_product_features = ProductFeatures.Export

      @wkf_initial_workflows = deep_copy(ProductControl.workflows)
      @wkf_initial_proposals = deep_copy(ProductControl.proposals)
      @wkf_initial_inst_finish = deep_copy(ProductControl.inst_finish)
      @wkf_initial_clone_modules = deep_copy(ProductControl.clone_modules)
      @wkf_initial_system_roles = deep_copy(ProductControl.system_roles)

      @additional_finish_steps_before_chroot = []
      @additional_finish_steps_after_chroot = []
      @additional_finish_steps_before_umount = []

      @base_workflow_stored = true

      nil
    end

    # Check all proposals, split those ones which have multiple modes or
    # architectures or stages into multiple proposals.
    #
    # @param list <map> current proposals
    # @return [Array<Hash>] updated proposals
    #
    #
    # **Structure:**
    #
    #
    #       Input: [
    #         $["label":"Example", "name":"example","proposal_modules":["one","two"],"stage":"initial,firstboot"]
    #       ]
    #       Output: [
    #         $["label":"Example", "name":"example","proposal_modules":["one","two"],"stage":"initial"]
    #         $["label":"Example", "name":"example","proposal_modules":["one","two"],"stage":"firstboot"]
    #       ]
    def PrepareProposals(proposals)
      proposals = deep_copy(proposals)
      new_proposals = []

      # Going through all proposals
      Builtins.foreach(proposals) do |one_proposal|
        mode = Ops.get_string(one_proposal, "mode", "")
        modes = Builtins.splitstring(mode, ",")
        modes = [""] if Builtins.size(modes) == 0
        # Going through all modes in proposal
        Builtins.foreach(modes) do |one_mode|
          mp = deep_copy(one_proposal)
          Ops.set(mp, "mode", one_mode)
          arch = Ops.get_string(one_proposal, "archs", "")
          archs = Builtins.splitstring(arch, ",")
          archs = [""] if Builtins.size(archs) == 0
          # Going through all architectures
          Builtins.foreach(archs) do |one_arch|
            amp = deep_copy(mp)
            Ops.set(amp, "archs", one_arch)
            stage = Ops.get_string(amp, "stage", "")
            stages = Builtins.splitstring(stage, ",")
            stages = [""] if Builtins.size(stages) == 0
            # Going through all stages
            Builtins.foreach(stages) do |one_stage|
              single_proposal = deep_copy(amp)
              Ops.set(single_proposal, "stage", one_stage)
              new_proposals = Builtins.add(new_proposals, single_proposal)
            end
          end
        end
      end

      deep_copy(new_proposals)
    end

    # Check all proposals, split those ones which have multiple modes or
    # architectures or stages into multiple proposals.
    # Works with base product proposals.
    def PrepareSystemProposals
      return if @system_proposals_prepared

      ProductControl.proposals = PrepareProposals(ProductControl.proposals)
      @system_proposals_prepared = true

      nil
    end

    # Check all workflows, split those ones which have multiple modes or
    # architectures or stages into multiple workflows
    # @param [Array<Hash>] workflows
    # @return [Array<Hash>] updated workflows
    def PrepareWorkflows(workflows)
      workflows = deep_copy(workflows)
      new_workflows = []

      # Going through all workflows
      Builtins.foreach(workflows) do |one_workflow|
        mode = Ops.get_string(one_workflow, "mode", "")
        modes = Builtins.splitstring(mode, ",")
        modes = [""] if Builtins.size(modes) == 0
        # Going through all modes
        Builtins.foreach(modes) do |one_mode|
          mw = deep_copy(one_workflow)
          Ops.set(mw, "mode", one_mode)
          Ops.set(mw, "defaults", Ops.get_map(mw, "defaults", {}))
          arch = Ops.get_string(mw, ["defaults", "archs"], "")
          archs = Builtins.splitstring(arch, ",")
          archs = [""] if Builtins.size(archs) == 0
          # Going through all architercures
          Builtins.foreach(archs) do |one_arch|
            amw = deep_copy(mw)
            Ops.set(amw, ["defaults", "archs"], one_arch)
            stage = Ops.get_string(amw, "stage", "")
            stages = Builtins.splitstring(stage, ",")
            stages = [""] if Builtins.size(stages) == 0
            # Going through all stages
            Builtins.foreach(stages) do |one_stage|
              single_workflow = deep_copy(amw)
              Ops.set(single_workflow, "stage", one_stage)
              new_workflows = Builtins.add(new_workflows, single_workflow)
            end
          end
        end
      end

      deep_copy(new_workflows)
    end

    # Check all workflows, split those ones which have multiple modes or
    # architectures or stages into multiple worlflows.
    # Works with base product workflows.
    def PrepareSystemWorkflows
      return if @system_workflows_prepared

      ProductControl.workflows = PrepareWorkflows(ProductControl.workflows)
      @system_workflows_prepared = true

      nil
    end

    # Fills the workflow with initial settings to start merging from scratch.
    # Used workflows mustn't be cleared automatically, merging would fail!
    def FillUpInitialWorkflowSettings
      if !@base_workflow_stored
        Builtins.y2error(
          "Base Workflow has never been stored, you should have called SetBaseWorkflow() before!"
        )
      end

      ProductFeatures.Import(@wkf_initial_product_features)

      ProductControl.workflows = deep_copy(@wkf_initial_workflows)
      ProductControl.proposals = deep_copy(@wkf_initial_proposals)
      ProductControl.inst_finish = deep_copy(@wkf_initial_inst_finish)
      ProductControl.clone_modules = deep_copy(@wkf_initial_clone_modules)
      ProductControl.system_roles = deep_copy(@wkf_initial_system_roles)

      @additional_finish_steps_before_chroot = []
      @additional_finish_steps_after_chroot = []
      @additional_finish_steps_before_umount = []

      @workflows_requiring_registration = []
      @workflows_to_sources = {}

      # reset internal variable to force the Prepare... function
      @system_proposals_prepared = false
      PrepareSystemProposals()

      # reset internal variable to force the Prepare... function
      @system_workflows_prepared = false
      PrepareSystemWorkflows()

      nil
    end

    # Resets the Workflow (and proposals) to use the base workflow. It must be stored.
    # Clears also all additional workflows.
    def ResetWorkflow
      FillUpInitialWorkflowSettings()
      @used_workflows = []

      nil
    end

    # Returns the current (default) directory where workflows are stored in.
    def GetWorkflowDirectory
      Builtins.sformat("%1/%2", Directory.tmpdir, @control_files_dir)
    end

    # Creates path to a control file from parameters. For add-on products,
    # the 'ident' parameter is empty.
    #
    # @param [Fixnum] src_id with source ID
    # @param [String] ident with pattern name (or another unique identification), empty for Add-Ons
    # @return [String] path to a control file based on src_id and ident params
    def GenerateAdditionalControlFilePath(src_id, ident)
      # special handling for Add-Ons (they have no special ident)
      ident = "__AddOnProduct-ControlFile__" if ident == ""

      Builtins.sformat("%1/%2:%3.xml", GetWorkflowDirectory(), src_id, ident)
    end

    # Stores the workflow file to a cache
    #
    # @param [String] file_from filename
    # @param [String] file_to filename
    # @return [String] final filename
    def StoreWorkflowFile(file_from, file_to)
      if file_from.nil? || file_from == "" || file_to.nil? || file_to == ""
        Builtins.y2error("Cannot copy '%1' to '%2'", file_from, file_to)
        return nil
      end

      # Return nil if cannot copy
      file_location = nil

      Builtins.y2milestone(
        "Copying workflow from '%1' to '%2'",
        file_from,
        file_to
      )
      cmd = Convert.to_map(
        SCR.Execute(
          path(".target.bash_output"),
          Builtins.sformat(
            "\n" \
              "/bin/mkdir -p '%1';\n" \
              "/bin/cp -v '%2' '%3';\n",
            String.Quote(GetWorkflowDirectory()),
            String.Quote(file_from),
            String.Quote(file_to)
          )
        )
      )

      # successfully copied
      if Ops.get_integer(cmd, "exit", -1) == 0
        file_location = file_to
      else
        Builtins.y2error("Error occurred while copying control file: %1", cmd)

        # Not in installation, try to skip the error
        if !Stage.initial && FileUtils.Exists(file_from)
          Builtins.y2milestone("Using fallback file %1", file_from)
          file_location = file_from
        end
      end

      file_location
    end

    # Download and extract the control file (installation.xml) from the add-on
    # repository.
    #
    # @param source [String, Fixnum] source where to get control file. It can be fixnum for
    #   addon type or package name for package type
    # @return [String, nil] path to downloaded installation.xml file or nil
    #   or nil when no workflow is defined or the workflow package is missing
    def control_file(source)
      package = case source
      when ::Integer
        product = find_product(source)
        return nil unless product && product["product_package"]

        product_package = product["product_package"]

        # the dependencies are bound to the product's -release package
        release_package = Pkg.ResolvableDependencies(product_package, :package, "").first

        # find the package name with installer update in its Provide dependencies
        control_file_package = find_control_package(release_package)
        return nil unless control_file_package

        control_file_package
      when ::String
        source
      else
        raise ArgumentError, "Invalid argument source #{source.inspect}"
      end

      # get the repository ID of the package
      src = package_repository(package)
      return nil unless src

      # ensure the previous content is removed, the src should avoid
      # collisions but rather be safe...
      dir = addon_control_dir(src, cleanup: true)
      fetch_package(src, package, dir)

      path = control_file_at_dir(dir)
      return nil unless File.exist?(path)

      log.info("installation.xml path: #{path}")
      path
    rescue ::Packages::PackageDownloader::FetchError
      # TRANSLATORS: an error message
      Report.Error(_("Downloading the installer extension package failed."))
      nil
    rescue ::Packages::PackageExtractor::ExtractionFailed
      # TRANSLATORS: an error message
      Report.Error(_("Extracting the installer extension failed."))
      nil
    end

    # Create a temporary directory for storing the installer extension package content.
    # The directory is automatically removed at exit.
    # @param src_id [Fixnum] repository ID
    # @param cleanup [Boolean] remove the content if the directory already exists
    # @return [String] directory path
    def addon_control_dir(src_id, cleanup: false)
      # Directory.tmpdir is automatically removed at exit
      dir = File.join(Directory.tmpdir, "installer-extension-#{src_id}")
      ::FileUtils.remove_entry(dir) if cleanup && Dir.exist?(dir)
      ::FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      dir
    end

    # Path of the control file contained in the package that has been previously
    # extracted to the given directory
    #
    # @see #control_file
    #
    # @param dir [String] directory where the package has been extracted to
    # @return [String] name of the control file
    def control_file_at_dir(dir)
      # Lets first try FHS compliant path for a product package (fate#325482)
      path = find_control_file("#{dir}/usr/share/installation-products")

      # If nothing there, try FHS compliant path for a role package (bsc#1114573)
      path ||= find_control_file("#{dir}/usr/share/system-roles")

      # As last resort, use the default location at /installation.xml
      path ||= File.join(dir, "installation.xml")

      path
    end

    # Full name of the control file located directly in the given directory
    #
    # The content of the file is not verified to be compliant with the structure
    # of a control file, this method simply finds the (hopefully only) XML file
    # in the directory.
    #
    # @param dir [String] directory where the control file is expected to be
    # @return [String, nil] nil if there is no control file
    def find_control_file(dir)
      # sadly no glob escaping - https://bugs.ruby-lang.org/issues/8258
      # but as we generate directory, it should be ok
      files = Dir.glob("#{dir}/*.xml")

      log.error "More than one XML file in #{dir}: #{files.inspect}" if files.size > 1

      files.first
    end

    # Returns requested control filename. Parameter 'name' is ignored
    # for Add-Ons.
    #
    # @param [Symbol] type :addon or :package
    # @param [Fixnum] src_id with Source ID
    # @param [String] name with unique identification, ignored for addon
    # @return [String] path to already cached workflow file, control file is downloaded if not yet cached
    #   or nil if failed to get filename
    def GetCachedWorkflowFilename(type, src_id, name = "")
      if ![:package, :addon].include?(type)
        Builtins.y2error("Unknown workflow type: %1", type)
        return nil
      end

      disk_filename = GenerateAdditionalControlFilePath(src_id, name)

      # A cached copy exists
      if FileUtils.Exists(disk_filename)
        Builtins.y2milestone("Using cached file %1", disk_filename)
        return disk_filename
        # Trying to get the file from source
      else
        Builtins.y2milestone("File %1 not cached", disk_filename)
        case type
        when :addon
          # using a file from source, works only for SUSE tags repositories
          use_filename = Pkg.SourceProvideDigestedFile(
            src_id,
            1,
            "/installation.xml",
            true
          )

          # The most generic way it to use the package referenced by the "installerextension()"
          # provides, this works with all repository types, including the RPM-MD repositories.
          use_filename ||= control_file(src_id)
        when :package
          use_filename = control_file(name)
        end

        # File exists?
        return use_filename.nil? ? nil : StoreWorkflowFile(use_filename, disk_filename)
      end
    ensure
      # release the media accessors (close server connections/unmount disks)
      Pkg.SourceReleaseAll
    end

    # Stores new workflow (if such workflow exists) into the Worflow Store.
    #
    # @param [Symbol] type :addon or :package
    # @param intger src_id with source ID
    # @param [String] name with unique identification name of the object
    #        ("" for `addon, package name for :package)
    # @return [Boolean] whether successful (true also in case of no workflow file)
    #
    # @example
    #  AddWorkflow (`addon, 4, "");
    def AddWorkflow(type, src_id, name)
      Builtins.y2milestone(
        "Adding Workflow:  Type %1, ID %2, Name %3",
        type,
        src_id,
        name
      )
      if !Builtins.contains([:addon, :package], type)
        Builtins.y2error("Unknown workflow type: %1", type)
        return false
      end

      name = "" if type == :addon
      # new xml filename
      used_filename = GetCachedWorkflowFilename(type, src_id, name)

      if !used_filename.nil? && used_filename != ""
        @unmerged_changes = true

        @used_workflows = Builtins.add(@used_workflows, used_filename)
        Ops.set(@workflows_to_sources, used_filename, src_id)
      end

      true
    end

    # Removes workflow (if such workflow exists) from the Worflow Store.
    # Alose removes the cached file but in the installation.
    #
    # @param [Symbol] type :addon or :package
    # @param [Integer] src_id with source ID
    # @param [String] name with unique identification name of the object.
    #   For :addon it should be empty string
    #
    # @return [Boolean] whether successful (true also in case of no workflow file)
    #
    # @example
    #  RemoveWorkflow (:addon, 4, "");
    def RemoveWorkflow(type, src_id, name)
      Builtins.y2milestone(
        "Removing Workflow:  Type %1, ID %2, Name %3",
        type,
        src_id,
        name
      )
      if !Builtins.contains([:addon, :package], type)
        Builtins.y2error("Unknown workflow type: %1", type)
        return false
      end

      name = "" if type == :addon
      # cached xml file
      used_filename = GenerateAdditionalControlFilePath(src_id, name)

      if !used_filename.nil? && used_filename != ""
        @unmerged_changes = true

        @used_workflows = Builtins.filter(@used_workflows) do |one_workflow|
          one_workflow != used_filename
        end

        if Builtins.haskey(@workflows_to_sources, used_filename)
          @workflows_to_sources = Builtins.remove(
            @workflows_to_sources,
            used_filename
          )
        end

        if !Stage.initial
          if FileUtils.Exists(used_filename)
            Builtins.y2milestone(
              "Removing cached file '%1': %2",
              used_filename,
              SCR.Execute(path(".target.remove"), used_filename)
            )
          end
        end
      end

      true
    end

    # Removes all xml and ycp files from directory where
    #
    # FIXME: this function seems to be unused, remove it?
    def CleanWorkflowsDirectory
      directory = GetWorkflowDirectory()
      Builtins.y2milestone(
        "Removing all xml and ycp files from '%1' directory",
        directory
      )

      if FileUtils.Exists(directory)
        # doesn't add RPM dependency on tar
        cmd = Convert.to_map(
          SCR.Execute(
            path(".target.bash_ouptut"),
            "\n" \
              "cd '%1';\n" \
              "/usr/bin/test -x /usr/bin/tar && /usr/bin/tar -zcf workflows_backup.tgz *.xml *.ycp *.rb;\n" \
              "/usr/bin/rm -rf *.xml *.ycp *.rb",
            String.Quote(directory)
          )
        )

        Builtins.y2error("Removing failed: %1", cmd) if Ops.get_integer(cmd, "exit", -1) != 0
      end

      nil
    end

    # Replace a module in a proposal with a set of other modules
    #
    # @param [Hash] proposal a map describing the proposal
    # @param [String] old string the old item to be replaced
    # @param [Array<String>] new a list of items to be put into instead of the old one
    # @return a map with the updated proposal
    def ReplaceProposalModule(proposal, old, new)
      proposal = deep_copy(proposal)
      new = deep_copy(new)
      found = false

      modules = Builtins.maplist(Ops.get_list(proposal, "proposal_modules", [])) do |m|
        if Ops.is_string?(m) && Convert.to_string(m) == old ||
            Ops.is_map?(m) &&
                Ops.get_string(Convert.to_map(m), "name", "") == old
          found = true

          next deep_copy(new) unless Ops.is_map?(m)

          Builtins.maplist(new) do |it|
            Builtins.union(Convert.to_map(m), "name" => it)
          end
        else
          [m]
        end
      end

      Builtins.y2internal("Replace/Remove proposal item %1 not found", old) if !found

      Ops.set(proposal, "proposal_modules", Builtins.flatten(modules))

      if Builtins.haskey(proposal, "proposal_tabs")
        Ops.set(
          proposal,
          "proposal_tabs",
          Builtins.maplist(Ops.get_list(proposal, "proposal_tabs", [])) do |tab|
            modules2 = Builtins.maplist(
              Ops.get_list(tab, "proposal_modules", [])
            ) do |m|
              (m == old) ? deep_copy(new) : [m]
            end

            Ops.set(tab, "proposal_modules", Builtins.flatten(modules2))
            deep_copy(tab)
          end
        )
      end

      deep_copy(proposal)
    end

    # Merge add-on proposal to a base proposal
    #
    # @param [Hash] base with the current product proposal
    # @param [Hash] additional_control with additional control file settings
    # @param [String] prod_name a name of the add-on product
    # @return [Hash] merged proposals
    def MergeProposal(base, additional_control, prod_name, domain)
      base = deep_copy(base)
      additional_control = deep_copy(additional_control)
      # Additional proposal settings - Replacing items
      replaces = Builtins.listmap(
        Ops.get_list(additional_control, "replace_modules", [])
      ) do |one_addon|
        old = Ops.get_string(one_addon, "replace", "")
        new = Ops.get_list(one_addon, "modules", [])
        { old => new }
      end

      if Ops.greater_than(
        Builtins.size(replaces),
        0
      )
        Builtins.foreach(replaces) do |old, new|
          base = ReplaceProposalModule(base, old, new)
        end
      end

      # Additional proposal settings - Removing settings
      removes = Ops.get_list(additional_control, "remove_modules", [])

      Builtins.foreach(removes) { |r| base = ReplaceProposalModule(base, r, []) } if Ops.greater_than(
        Builtins.size(removes),
        0
      )

      # Additional proposal settings - - Appending settings
      appends = Ops.get_list(additional_control, "append_modules", [])

      if Ops.greater_than(Builtins.size(appends), 0)
        append2 = deep_copy(appends)

        if Ops.is_map?(Ops.get(base, ["proposal_modules", 0]))
          append2 = Builtins.maplist(appends) do |m|
            { "name" => m, "presentation_order" => 9999 }
          end
        end

        Ops.set(
          base,
          "proposal_modules",
          Builtins.merge(Ops.get_list(base, "proposal_modules", []), append2)
        )

        if Builtins.haskey(base, "proposal_tabs")
          new_tab = {
            "label"            => prod_name,
            "proposal_modules" => appends,
            "textdomain"       => domain
          }
          Ops.set(
            base,
            "proposal_tabs",
            Builtins.add(Ops.get_list(base, "proposal_tabs", []), new_tab)
          )
        end
      end

      Ops.set(base, "enable_skip", "no") if Ops.get_string(additional_control, "enable_skip", "yes") == "no"

      deep_copy(base)
    end

    # Update system proposals according to proposal update metadata
    #
    # @param [Array<Hash>] proposals a list of update proposals
    # @param [String] prod_name string the product name (used in case of tabs)
    # @param [String] domain string the text domain (for translations)
    # @return [Boolean] true on success
    def UpdateProposals(proposals, prod_name, domain)
      proposals = deep_copy(proposals)
      Builtins.foreach(proposals) do |proposal|
        name = Ops.get_string(proposal, "name", "")
        stage = Ops.get_string(proposal, "stage", "")
        mode = Ops.get_string(proposal, "mode", "")
        arch = Ops.get_string(proposal, "archs", "")
        found = false
        new_proposals = []
        arch_all_prop = {}
        Builtins.foreach(ProductControl.proposals) do |p|
          if Ops.get_string(p, "stage", "") != stage ||
              Ops.get_string(p, "mode", "") != mode ||
              Ops.get_string(p, "name", "") != name
            new_proposals = Builtins.add(new_proposals, p)
            next
          end
          if [Ops.get_string(p, "archs", ""), "", "all"].include?(arch)
            p = MergeProposal(p, proposal, prod_name, domain)
            found = true
          elsif ["", "all"].include?(Ops.get_string(p, "archs", ""))
            arch_all_prop = deep_copy(p)
          end
          new_proposals = Builtins.add(new_proposals, p)
        end
        if !found
          if arch_all_prop != {}
            Ops.set(arch_all_prop, "archs", arch)
            proposal = MergeProposal(arch_all_prop, proposal, prod_name, domain)
            # completly new proposal
          else
            Ops.set(proposal, "textdomain", domain)
          end

          new_proposals = Builtins.add(new_proposals, proposal)
        end
        ProductControl.proposals = deep_copy(new_proposals)
      end

      true
    end

    # Replace a module in a workflow with a set of other modules
    #
    # @param [Hash] workflow a map describing the workflow
    # @param [String] old string the old item to be replaced
    # @param [Array<Hash>] new a list of items to be put into instead of the old one
    # @param [String] domain string a text domain
    # @param [Boolean] keep boolean true to keep original one (and just insert before)
    # @return a map with the updated workflow
    def ReplaceWorkflowModule(workflow, old, new, domain, keep)
      workflow = deep_copy(workflow)
      new = deep_copy(new)
      found = false

      modules = Builtins.maplist(Ops.get_list(workflow, "modules", [])) do |m|
        next [m] if Ops.get_string(m, "name", "") != old

        new_list = Builtins.maplist(new) do |n|
          Ops.set(n, "textdomain", domain)
          deep_copy(n)
        end

        found = true

        new_list = Builtins.add(new_list, m) if keep

        deep_copy(new_list)
      end

      log.warn("Insert/Replace/Remove workflow module '#{old}' not found") if !found
      Ops.set(workflow, "modules", Builtins.flatten(modules))
      deep_copy(workflow)
    end

    # Merge add-on workflow to a base workflow
    #
    # @param [Hash] base map the base product workflow
    # @param [Hash] addon map the workflow of the addon product
    # @param [String] prod_name a name of the add-on product
    # @return [Hash] merged workflows
    def MergeWorkflow(base, addon, _prod_name, domain)
      base = deep_copy(base)
      addon = deep_copy(addon)

      log.info "merging workflow #{addon.inspect} to #{base.inspect}"

      # Merging - removing steps, settings
      removes = Ops.get_list(addon, "remove_modules", [])

      if Ops.greater_than(Builtins.size(removes), 0)
        Builtins.y2milestone("Remove: %1", removes)
        Builtins.foreach(removes) do |r|
          base = ReplaceWorkflowModule(base, r, [], domain, false)
        end
      end

      # Merging - replacing steps, settings
      replaces = Builtins.listmap(Ops.get_list(addon, "replace_modules", [])) do |a|
        old = Ops.get_string(a, "replace", "")
        new = Ops.get_list(a, "modules", [])
        { old => new }
      end

      if Ops.greater_than(Builtins.size(replaces), 0)
        Builtins.y2milestone("Replace: %1", replaces)
        Builtins.foreach(replaces) do |old, new|
          base = ReplaceWorkflowModule(base, old, new, domain, false)
        end
      end

      # Merging - inserting steps, settings
      inserts = Builtins.listmap(Ops.get_list(addon, "insert_modules", [])) do |i|
        before = Ops.get_string(i, "before", "")
        new = Ops.get_list(i, "modules", [])
        { before => new }
      end

      if Ops.greater_than(Builtins.size(inserts), 0)
        Builtins.y2milestone("Insert: %1", inserts)
        Builtins.foreach(inserts) do |old, new|
          base = ReplaceWorkflowModule(base, old, new, domain, true)
        end
      end

      # Merging - appending steps, settings
      appends = Ops.get_list(addon, "append_modules", [])

      if Ops.greater_than(Builtins.size(appends), 0)
        Builtins.y2milestone("Append: %1", appends)
        Builtins.foreach(appends) do |new|
          Ops.set(new, "textdomain", domain)
          Ops.set(
            base,
            "modules",
            Builtins.add(Ops.get_list(base, "modules", []), new)
          )
        end
      end

      log.info "result of merge #{base.inspect}"
      deep_copy(base)
    end

    # Update system workflows according to workflow update metadata
    #
    # @param [Array<Hash>] workflows a list of update workflows
    # @param [String] prod_name string the product name (used in case of tabs)
    # @param [String] domain string the text domain (for translations)
    # @return [Boolean] true on success
    def UpdateWorkflows(workflows, prod_name, domain)
      workflows = deep_copy(workflows)
      Builtins.foreach(workflows) do |workflow|
        stage = Ops.get_string(workflow, "stage", "")
        mode = Ops.get_string(workflow, "mode", "")
        arch = Ops.get_string(workflow, "archs", "")
        found = false
        new_workflows = []
        arch_all_wf = {}
        log.info "workflow to update #{workflow.inspect}"

        Builtins.foreach(ProductControl.workflows) do |w|
          if Ops.get_string(w, "stage", "") != stage ||
              Ops.get_string(w, "mode", "") != mode
            new_workflows = Builtins.add(new_workflows, w)
            next
          end
          if [Ops.get_string(w, ["defaults", "archs"], ""), "", "all"].include?(arch)
            w = MergeWorkflow(w, workflow, prod_name, domain)
            found = true
          elsif ["", "all"].include?(Ops.get_string(w, ["defaults", "archs"], ""))
            arch_all_wf = deep_copy(w)
          end
          new_workflows = Builtins.add(new_workflows, w)
        end
        if !found
          if arch_all_wf != {}
            Ops.set(arch_all_wf, ["defaults", "archs"], arch)
            workflow = MergeWorkflow(arch_all_wf, workflow, prod_name, domain)
          # completly new workflow
          else
            # If modules has not been defined we are trying to use the appended modules
            workflow["modules"] = workflow["append_modules"] unless workflow["modules"]

            Ops.set(workflow, "textdomain", domain)

            Ops.set(
              workflow,
              "modules",
              Builtins.maplist(Ops.get_list(workflow, "modules", [])) do |mod|
                Ops.set(mod, "textdomain", domain)
                deep_copy(mod)
              end
            )
          end

          new_workflows = Builtins.add(new_workflows, workflow)
        end

        log.info "new workflow after update #{new_workflows}"

        ProductControl.workflows = deep_copy(new_workflows)
      end

      true
    end

    # Update sytem roles according to the update section of the control file
    #
    # The hash is expectd to have the following structure:
    #
    # "insert_system_roles" => [
    #   {
    #    "system_roles" =>
    #      [
    #        { "id" => "additional_role1" },
    #        { "id" => "additional_role2" }
    #      ]
    #   }
    # ]
    #
    # @param new_roles [Hash] System roles specification
    #
    # @see ProductControl#add_system_roles
    def update_system_roles(system_roles)
      system_roles.fetch("insert_system_roles", []).each do |insert|
        ProductControl.add_system_roles(insert["system_roles"])
      end
    end

    # Add specified steps to inst_finish.
    # Just modifies internal variables, inst_finish grabs them itself
    #
    # @param [Hash{String => Array<String>}] additional_steps a map specifying the steps to be added
    # @return [Boolean] true on success
    def UpdateInstFinish(additional_steps)
      additional_steps = deep_copy(additional_steps)
      before_chroot = Ops.get(additional_steps, "before_chroot", [])
      after_chroot = Ops.get(additional_steps, "after_chroot", [])
      before_umount = Ops.get(additional_steps, "before_umount", [])

      @additional_finish_steps_before_chroot = Convert.convert(
        Builtins.merge(@additional_finish_steps_before_chroot, before_chroot),
        from: "list",
        to:   "list <string>"
      )

      @additional_finish_steps_after_chroot = Convert.convert(
        Builtins.merge(@additional_finish_steps_after_chroot, after_chroot),
        from: "list",
        to:   "list <string>"
      )

      @additional_finish_steps_before_umount = Convert.convert(
        Builtins.merge(@additional_finish_steps_before_umount, before_umount),
        from: "list",
        to:   "list <string>"
      )

      true
    end

    # Adapts the current workflow according to specified XML file content
    #
    # @param [Hash] update_file a map containing the additional product control file
    # @param [String] name string the name of the additional product
    # @param [String] domain string the text domain for the additional control file
    #
    # @return [Boolean] true on success
    def UpdateInstallation(update_file, name, domain)
      log.info "Updating installation workflow: #{update_file.inspect}"
      update_file = deep_copy(update_file)
      PrepareSystemProposals()
      PrepareSystemWorkflows()

      proposals = Ops.get_list(update_file, "proposals", [])
      proposals = PrepareProposals(proposals)
      UpdateProposals(proposals, name, domain)

      workflows = Ops.get_list(update_file, "workflows", [])
      workflows = PrepareWorkflows(workflows)
      UpdateWorkflows(workflows, name, domain)

      update_system_roles(update_file.fetch("system_roles", {}))

      true
    end

    # Add new defined proposal to the list of system proposals
    #
    # @param [Array<Hash>] proposals a list of proposals to be added
    # @return [Boolean] true on success
    def AddNewProposals(proposals)
      proposals = deep_copy(proposals)
      forbidden = Builtins.maplist(ProductControl.proposals) do |p|
        Ops.get_string(p, "name", "")
      end

      forbidden = Builtins.toset(forbidden)

      Builtins.foreach(proposals) do |proposal|
        if !Builtins.contains(forbidden, Ops.get_string(proposal, "name", ""))
          Builtins.y2milestone(
            "Adding new proposal %1",
            Ops.get_string(proposal, "name", "")
          )
          ProductControl.proposals = Builtins.add(
            ProductControl.proposals,
            proposal
          )
        else
          Builtins.y2warning(
            "Proposal '%1' already exists, not adding",
            Ops.get_string(proposal, "name", "")
          )
        end
      end

      true
    end

    # Replace workflows for 2nd stage of installation
    #
    # @param [Array<Hash>] workflows a list of the workflows
    # @return [Boolean] true on success
    def Replaceworkflows(workflows)
      workflows = deep_copy(workflows)
      workflows = PrepareWorkflows(workflows)

      # This function doesn't update the current workflow but replaces it.
      # That's why it is not allowed for the first stage of the installation.
      workflows = Builtins.filter(workflows) do |workflow|
        if Ops.get_string(workflow, "stage", "") == "initial"
          Builtins.y2error(
            "Attempting to replace 1st stage workflow. This is not possible"
          )
          Builtins.y2milestone("Workflow: %1", workflow)
          next false
        end
        true
      end

      sm = {}

      Builtins.foreach(workflows) do |workflow|
        Ops.set(
          sm,
          Ops.get_string(workflow, "stage", ""),
          Ops.get(sm, Ops.get_string(workflow, "stage", ""), {})
        )
        Ops.set(
          sm,
          [
            Ops.get_string(workflow, "stage", ""),
            Ops.get_string(workflow, "mode", "")
          ],
          true
        )
        [
          Ops.get_string(workflow, "stage", ""),
          Ops.get_string(workflow, "mode", "")
        ]
      end

      Builtins.y2milestone("Existing replace workflows: %1", sm)
      Builtins.y2milestone(
        "Workflows before filtering: %1",
        Builtins.size(ProductControl.workflows)
      )

      ProductControl.workflows = Builtins.filter(ProductControl.workflows) do |w|
        !Ops.get(
          sm,
          [Ops.get_string(w, "stage", ""), Ops.get_string(w, "mode", "")],
          false
        )
      end

      Builtins.y2milestone(
        "Workflows after filtering: %1",
        Builtins.size(ProductControl.workflows)
      )
      ProductControl.workflows = Convert.convert(
        Builtins.merge(ProductControl.workflows, workflows),
        from: "list",
        to:   "list <map>"
      )

      true
    end

    # Returns list of workflows requiring registration
    #
    # @see FATE #305578: Add-On Product Requiring Registration
    def WorkflowsRequiringRegistration
      deep_copy(@workflows_requiring_registration)
    end

    # Returns whether a repository workflow requires registration
    #
    # @param [Fixnum] src_id
    # @return [Boolean] if registration is required
    def WorkflowRequiresRegistration(src_id)
      ret = false

      Builtins.y2milestone("Known workflows: %1", @workflows_to_sources)
      Builtins.y2milestone(
        "Workflows requiring registration: %1",
        @workflows_requiring_registration
      )

      Builtins.foreach(@workflows_to_sources) do |one_workflow, id|
        # sources match and workflow is listed as 'requiring registration'
        if src_id == id &&
            Builtins.contains(@workflows_requiring_registration, one_workflow)
          ret = true
          raise Break
        end
      end

      Builtins.y2milestone("WorkflowRequiresRegistration(%1): %2", src_id, ret)
      ret
    end

    def IncorporateControlFileOptions(filename)
      update_file = XML.XMLToYCPFile(filename)
      if update_file.nil?
        Builtins.y2error("Unable to read the %1 control file", filename)
        return false
      end

      # FATE #305578: Add-On Product Requiring Registration
      globals = Ops.get_map(update_file, "globals", {})

      if Builtins.haskey(globals, "require_registration") &&
          Ops.get_boolean(globals, "require_registration", false) == true
        Builtins.y2milestone("Registration is required by %1", filename)
        @workflows_requiring_registration = Builtins.toset(
          Builtins.add(@workflows_requiring_registration, filename)
        )
        Builtins.y2milestone(
          "Workflows requiring registration: %1",
          @workflows_requiring_registration
        )
      else
        Builtins.y2milestone("Registration is not required by %1", filename)
      end

      true
    end

    # Update product options such as global settings, software, partitioning
    # or network.
    #
    # @param [Hash] update_file a map containing update control file
    # @param
    # @return [Boolean] true on success
    def UpdateProductInfo(update_file, _filename)
      update_file = deep_copy(update_file)
      # merging all 'map <string, any>' type
      Builtins.foreach(["globals", "software", "partitioning", "network"]) do |section|
        sect = ProductFeatures.GetSection(section)
        addon = Ops.get_map(update_file, section, {})
        sect = Convert.convert(
          Builtins.union(sect, addon),
          from: "map",
          to:   "map <string, any>"
        )
        ProductFeatures.SetSection(section, sect)
      end

      # merging 'clone_modules'
      addon_clone = Ops.get_list(update_file, "clone_modules", [])
      ProductControl.clone_modules = Convert.convert(
        Builtins.merge(ProductControl.clone_modules, addon_clone),
        from: "list",
        to:   "list <string>"
      )

      # merging texts

      #
      # **Structure:**
      #
      #     $[
      #        "congratulate" : $[
      #          "label" : "some text",
      #        ],
      #        "congratulate2" : $[
      #          "label" : "some other text",
      #          "textdomain" : "control-2", // (optionally)
      #        ],
      #      ];
      controlfile_texts = ProductFeatures.GetSection("texts")
      update_file_texts = Ops.get_map(update_file, "texts", {})
      update_file_textdomain = Ops.get_string(update_file, "textdomain", "")

      # if textdomain is different to the base one
      # we have to put it into the map
      if !update_file_textdomain.nil? && update_file_textdomain != ""
        update_file_texts = Builtins.mapmap(update_file_texts) do |text_ident, text_def|
          Ops.set(text_def, "textdomain", update_file_textdomain)
          { text_ident => text_def }
        end
      end

      controlfile_texts = Convert.convert(
        Builtins.union(controlfile_texts, update_file_texts),
        from: "map",
        to:   "map <string, any>"
      )
      ProductFeatures.SetSection("texts", controlfile_texts)

      true
    end

    # Redraws workflow steps. Function must be called when steps (or help for steps)
    # are active. It doesn't work in case of active another dialog.
    def RedrawWizardSteps
      Builtins.y2milestone("Retranslating messages, redrawing wizard steps")

      # Make sure the labels for default function keys are retranslated, too.
      # Using Label::DefaultFunctionKeyMap() from Label module.
      UI.SetFunctionKeys(Label.DefaultFunctionKeyMap)

      # Activate language changes on static part of wizard dialog
      ProductControl.RetranslateWizardSteps
      Wizard.RetranslateButtons
      Wizard.SetFocusToNextButton

      true
    end

    # Integrate the changes in the workflow
    # @param [String] filename string filename of the control file (local filename)
    # @return [Boolean] true on success
    def IntegrateWorkflow(filename)
      Builtins.y2milestone("IntegrateWorkflow %1", filename)

      update_file = XML.XMLToYCPFile(filename)
      name = Ops.get_string(update_file, "display_name", "")

      if !UpdateInstallation(
        Ops.get_map(update_file, "update", {}),
        name,
        Ops.get_string(update_file, "textdomain", "control")
      )
        Builtins.y2error("Failed to update installation workflow")
        return false
      end

      if !UpdateProductInfo(update_file, filename)
        Builtins.y2error("Failed to set product options")
        return false
      end

      if !AddNewProposals(Ops.get_list(update_file, "proposals", []))
        Builtins.y2error("Failed to add new proposals")
        return false
      end

      if !Replaceworkflows(Ops.get_list(update_file, "workflows", []))
        Builtins.y2error("Failed to replace workflows")
        return false
      end

      if !UpdateInstFinish(
        Ops.get_map(update_file, ["update", "inst_finish"], {})
      )
        Builtins.y2error("Adding inst_finish steps failed")
        return false
      end

      true
    end

    # Returns file unique identification in format <file_MD5sum>-<file_size>
    # Returns 'nil' if file doesn't exist, it is not a 'file', etc.
    #
    # @param string file
    # @return [String] file_ident
    def GenerateWorkflowIdent(workflow_filename)
      file_md5sum = FileUtils.MD5sum(workflow_filename)

      if file_md5sum.nil? || file_md5sum == ""
        Builtins.y2error(
          "MD5 sum of file %1 is %2",
          workflow_filename,
          file_md5sum
        )
        return nil
      end

      file_size = FileUtils.GetSize(workflow_filename)

      if Ops.less_than(file_size, 0)
        Builtins.y2error("File size %1 is %2", workflow_filename, file_size)
        return nil
      end

      Builtins.sformat("%1-%2", file_md5sum, file_size)
    end

    # Function uses the Base Workflow as the initial one and merges all
    # added workflow into that workflow.
    #
    # @return [Boolean] if successful
    def MergeWorkflows
      Builtins.y2milestone("Merging additional control files from scratch...")
      @unmerged_changes = false

      # Init the Base Workflow settings
      FillUpInitialWorkflowSettings()

      ret = true

      already_merged_workflows = []

      @merge_counter += 1
      add_on_counter = 1

      Builtins.foreach(@used_workflows) do |one_workflow|
        # make sure that every workflow is merged only once
        # bugzilla #332436
        workflow_ident = GenerateWorkflowIdent(one_workflow)
        if !workflow_ident.nil? &&
            Builtins.contains(already_merged_workflows, workflow_ident)
          Builtins.y2milestone(
            "The very same workflow has been already merged, skipping..."
          )
          next
        elsif !workflow_ident.nil?
          already_merged_workflows = Builtins.add(
            already_merged_workflows,
            workflow_ident
          )
        else
          Builtins.y2error("Workflow ident is: %1", workflow_ident)
        end

        # log the installation.xml being merged

        control_log_dir_rotator = Yast2::ControlLogDirRotator.new
        control_log_dir_rotator.copy(one_workflow, "/#{format("%02d", @merge_counter)}-#{format("%02d", add_on_counter)}-installation.xml")
        add_on_counter += 1

        IncorporateControlFileOptions(one_workflow)
        if !IntegrateWorkflow(one_workflow)
          Builtins.y2error("Merging '%1' failed!", one_workflow)
          Report.Error(
            _(
              "An internal error occurred when integrating additional workflow."
            )
          )
          ret = false
        end
      end

      ret
    end

    # Returns whether some additional control files were added or removed
    # from the last time MergeWorkflows() was called.
    #
    # @return boolen see description
    def SomeWorkflowsWereChanged
      @unmerged_changes
    end

    # Returns list of control-file names currently used
    #
    # @return [Array<String>] files
    def GetAllUsedControlFiles
      deep_copy(@used_workflows)
    end

    # Sets list of control-file names to be used.
    # ATTENTION: this is dangerous and should be used in rare cases only!
    #
    # @see #GetAllUsedControlFiles()
    # @param list <string> new workflows (XML files in absolute-path format)
    # @example
    #  SetAllUsedControlFiles (["/tmp/new_addon_control.xml", "/root/special_addon.xml"]);
    def SetAllUsedControlFiles(new_list)
      new_list = deep_copy(new_list)
      Builtins.y2milestone("New list of additional workflows: %1", new_list)
      @unmerged_changes = true
      @used_workflows = deep_copy(new_list)

      nil
    end

    # Returns whether some additional control files are currently in use.
    #
    # @return [Boolean] some additional control files are in use.
    def HaveAdditionalWorkflows
      Ops.greater_or_equal(Builtins.size(GetAllUsedControlFiles()), 0)
    end

    # Returns the current settings used by WorkflowManager.
    # This function is just for debugging purpose.
    #
    # @return [Hash{String => Object}] of current settings
    #
    # **Structure:**
    #
    #     [
    #         "workflows" : ...
    #         "proposals" : ...
    #         "inst_finish" : ...
    #         "clone_modules" : ...
    #         "system_roles" : ...
    #         "unmerged_changes" : ...
    #       ];
    def DumpCurrentSettings
      {
        "workflows"        => ProductControl.workflows,
        "proposals"        => ProductControl.proposals,
        "inst_finish"      => ProductControl.inst_finish,
        "clone_modules"    => ProductControl.clone_modules,
        "system_roles"     => ProductControl.system_roles,
        "unmerged_changes" => @unmerged_changes
      }
    end

    # Merge product's workflow
    #
    # @param product [Y2Packager::Product] Base product
    def merge_product_workflow(product)
      return false unless product.installation_package

      log.info "Merging #{product.label} workflow"

      if merged_base_product
        Yast::WorkflowManager.RemoveWorkflow(
          :package,
          merged_base_product.installation_package_repo,
          merged_base_product.installation_package
        )
      end

      AddWorkflow(:package, product.installation_package_repo, product.installation_package)
      MergeWorkflows()
      RedrawWizardSteps()
      self.merged_base_product = product
    end

    # Merge modules extensions
    #
    # @param packages [Array<String>] packages that extends workflow
    def merge_modules_extensions(packages)
      log.info "Merging #{packages} workflow"

      merged_modules_extensions.each do |pkg|
        Yast::WorkflowManager.RemoveWorkflow(:package, 0, pkg)
      end

      packages.each do |pkg|
        AddWorkflow(:package, 0, pkg)
      end
      MergeWorkflows()
      RedrawWizardSteps()

      self.merged_modules_extensions = packages
    end

    publish variable: :additional_finish_steps_before_chroot, type: "list <string>"
    publish variable: :additional_finish_steps_after_chroot, type: "list <string>"
    publish variable: :additional_finish_steps_before_umount, type: "list <string>"
    publish function: :GetAdditionalFinishSteps, type: "list <string> (string)"
    publish function: :SetBaseWorkflow, type: "void (boolean)"
    publish function: :PrepareProposals, type: "list <map> (list <map>)"
    publish function: :PrepareSystemProposals, type: "void ()"
    publish function: :PrepareWorkflows, type: "list <map> (list <map>)"
    publish function: :PrepareSystemWorkflows, type: "void ()"
    publish function: :ResetWorkflow, type: "void ()"
    publish function: :GetCachedWorkflowFilename, type: "string (symbol, integer, string)"
    publish function: :AddWorkflow, type: "boolean (symbol, integer, string)"
    publish function: :RemoveWorkflow, type: "boolean (symbol, integer, string)"
    publish function: :CleanWorkflowsDirectory, type: "void ()"
    publish function: :WorkflowsRequiringRegistration, type: "list <string> ()"
    publish function: :WorkflowRequiresRegistration, type: "boolean (integer)"
    publish function: :IncorporateControlFileOptions, type: "boolean (string)"
    publish function: :RedrawWizardSteps, type: "boolean ()"
    publish function: :MergeWorkflows, type: "boolean ()"
    publish function: :SomeWorkflowsWereChanged, type: "boolean ()"
    publish function: :GetAllUsedControlFiles, type: "list <string> ()"
    publish function: :SetAllUsedControlFiles, type: "void (list <string>)"
    publish function: :HaveAdditionalWorkflows, type: "boolean ()"
    publish function: :DumpCurrentSettings, type: "map <string, any> ()"

  private

    # @return [Y2Packager::Product,nil] Product or nil if no base product workflow was merged.
    attr_accessor :merged_base_product

    # @return [Array<String>] list of modules that have registered extensions
    attr_accessor :merged_modules_extensions

    # Find the product from a repository.
    # @param repo_id [Fixnum] repository ID
    # @return [Hash,nil] pkg-bindings product hash or nil if not found
    def find_product(repo_id)
      # identify the product
      products = Pkg.ResolvableDependencies("", :product, "")
      return nil unless products

      products.select! { |p| p["source"] == repo_id }

      if products.size > 1
        log.warn("More than one product found in the repository: #{products}")
        log.warn("Using the first one: #{products.first}")
      end

      products.first
    end

    # Find the extension package name for the specified release package.
    # The extension package is defined by the "installerextension()"
    # RPM "Provides" dependency.
    # @return [String,nil] a package name or nil if not found
    def find_control_package(release_package)
      return nil unless release_package && release_package["deps"]

      release_package["deps"].each do |dep|
        provide = dep["provides"]
        next unless provide

        control_file_package = provide[/\Ainstallerextension\((.+)\)\z/, 1]
        next unless control_file_package

        log.info("Found referenced package with control file: #{control_file_package}")
        return control_file_package.strip
      end

      nil
    end

    # Find the repository ID for the package.
    # @param package_name [String] name of the package
    # @return [Fixnum,nil] repository ID or nil if not found
    def package_repository(package_name)
      # Identify the installation repository with the package
      pkgs = Pkg.ResolvableProperties(package_name, :package, "")

      if pkgs.empty?
        log.warn("The installer extension package #{package_name} was not found")
        return nil
      end

      latest_package = pkgs.reduce(nil) do |a, p|
        (!a || (Pkg.CompareVersions(a["version"], p["version"]) < 0)) ? p : a
      end

      if pkgs.size > 1
        log.warn("More than one control package found: #{pkgs}")
        log.info("Using the latest package: #{latest_package}")
      end

      latest_package["source"]
    end

    # Download and extract a package from a repository.
    # @param repo_id [Fixnum] repository ID
    # @param package [String] name of the package
    # @raise [::Packages::PackageDownloader::FetchError] if package download failed
    # @raise [::Packages::PackageExtractor::ExtractionFailed] if package extraction failed
    def fetch_package(repo_id, package, dir)
      downloader = ::Packages::PackageDownloader.new(repo_id, package)

      Tempfile.open("downloaded-package-") do |tmp|
        downloader.download(tmp.path)
        extract(tmp.path, dir)
        # the RPM package file is not needed after extracting it's content,
        # remove it explicitly now, do not wait for the garbage collector
        # (in inst-syst it is stored in a RAM disk and eats the RAM memory)
        tmp.unlink
      end
    end

    # Extract an RPM package into the given directory.
    # @param package_file [String] the RPM package path
    # @param dir [String] a directory where the package will be extracted to
    # @raise [::Packages::PackageExtractor::ExtractionFailed] if package extraction failed
    def extract(package_file, dir)
      log.info("Extracting file #{package_file}")
      extractor = ::Packages::PackageExtractor.new(package_file)
      extractor.extract(dir)
    end
  end

  WorkflowManager = WorkflowManagerClass.new
  WorkflowManager.main
end
