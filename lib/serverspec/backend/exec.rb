require 'singleton'

module Serverspec
  module Backend
    class Exec < Base

      def run_command(cmd, opts={})
        cmd = build_command(cmd)
        cmd = add_pre_command(cmd)
        stdout = `#{build_command(cmd)} 2>&1`
        # In ruby 1.9, it is possible to use Open3.capture3, but not in 1.8
        #stdout, stderr, status = Open3.capture3(cmd)

        if @example
          @example.metadata[:command] = cmd
          @example.metadata[:stdout]  = stdout
        end

        { :stdout => stdout, :stderr => nil,
          :exit_status => $?.exitstatus, :exit_signal => nil }
      end

      def build_command(cmd)
        path = Serverspec.configuration.path || RSpec.configuration.path
        if path
          cmd = "env PATH=#{path}:$PATH #{cmd}"
          cmd.gsub!(/(\&\&\s*!?\(?\s*)/, "\\1env PATH=#{path}:$PATH ")
          cmd.gsub!(/(\|\|\s*!?\(?\s*)/, "\\1env PATH=#{path}:$PATH ")
        end
        cmd
      end

      def add_pre_command(cmd)
        path = Serverspec.configuration.path || RSpec.configuration.path
        if Serverspec.configuration.pre_command
          cmd = "#{Serverspec.configuration.pre_command} && #{cmd}"
          cmd = "env PATH=#{path}:$PATH #{cmd}" if path
        end
        cmd
      end

      def check_running(process)
        ret = run_command(commands.check_running(process))
        
        # In Ubuntu, some services are under upstart and "service foo status" returns
        # exit status 0 even though they are stopped.
        # So return false if stdout contains "stopped/waiting".
        return false if ret[:stdout] =~ /stopped\/waiting/

        # If the service is not registered, check by ps command
        if ret[:exit_status] == 1
          ret = run_command(commands.check_process(process))
        end

        ret[:exit_status] == 0
      end

      def check_monitored_by_monit(process)
        ret = run_command(commands.check_monitored_by_monit(process))
        return false unless ret[:stdout] != nil && ret[:exit_status] == 0

        retlines = ret[:stdout].split(/[\r\n]+/).map(&:strip)
        proc_index = retlines.index("Process '#{process}'")
        return false unless proc_index
        
        retlines[proc_index+2].match(/\Amonitoring status\s+monitored\Z/i) != nil
      end

      def check_readable(file, by_whom)
        mode = sprintf('%04s',run_command(commands.get_mode(file))[:stdout].strip)
        mode = mode.split('')
        mode_octal = mode[0].to_i * 512 + mode[1].to_i * 64 + mode[2].to_i * 8 + mode[3].to_i * 1
        case by_whom
        when nil
          mode_octal & 0444 != 0
        when 'owner'
          mode_octal & 0400 != 0
        when 'group'
          mode_octal & 0040 != 0
        when 'others'
          mode_octal & 0004 != 0
        end
      end

      def check_writable(file, by_whom)
        mode = sprintf('%04s',run_command(commands.get_mode(file))[:stdout].strip)
        mode = mode.split('')
        mode_octal = mode[0].to_i * 512 + mode[1].to_i * 64 + mode[2].to_i * 8 + mode[3].to_i * 1
        case by_whom
        when nil
          mode_octal & 0222 != 0
        when 'owner'
          mode_octal & 0200 != 0
        when 'group'
          mode_octal & 0020 != 0
        when 'others'
          mode_octal & 0002 != 0
        end
      end

      def check_executable(file, by_whom)
        mode = sprintf('%04s',run_command(commands.get_mode(file))[:stdout].strip)
        mode = mode.split('')
        mode_octal = mode[0].to_i * 512 + mode[1].to_i * 64 + mode[2].to_i * 8 + mode[3].to_i * 1
        case by_whom
        when nil
          mode_octal & 0111 != 0
        when 'owner'
          mode_octal & 0100 != 0
        when 'group'
          mode_octal & 0010 != 0
        when 'others'
          mode_octal & 0001 != 0
        end
      end

      def check_mounted(path, expected_attr, only_with)
        ret = run_command(commands.check_mounted(path))
        if expected_attr.nil? || ret[:exit_status] != 0
          return ret[:exit_status] == 0
        end

        mount = ret[:stdout].scan(/\S+/)
        actual_attr    = { :device => mount[0], :type => mount[4] }
        mount[5].gsub(/\(|\)/, '').split(',').each do |option|
          name, val = option.split('=')
          if val.nil?
            actual_attr[name.to_sym] = true
          else
            val = val.to_i if val.match(/^\d+$/)
            actual_attr[name.to_sym] = val
          end
        end

        if ! expected_attr[:options].nil?
          expected_attr.merge!(expected_attr[:options])
          expected_attr.delete(:options)
        end

        if only_with
          actual_attr == expected_attr
        else
          expected_attr.each do |key, val|
            return false if actual_attr[key] != val
          end
          true
        end
      end

      def check_routing_table(expected_attr)
        return false if ! expected_attr[:destination]
        ret = run_command(commands.check_routing_table(expected_attr[:destination]))
        return false if ret[:exit_status] != 0

        ret[:stdout] =~ /^(\S+)(?: via (\S+))? dev (\S+).+\r\n(?:default via (\S+))?/
        actual_attr = {
          :destination => $1,
          :gateway     => $2 ? $2 : $4,
          :interface   => expected_attr[:interface] ? $3 : nil
        }

        expected_attr.each do |key, val|
          return false if actual_attr[key] != val
        end
        true
      end

      def check_os
        return RSpec.configuration.os if RSpec.configuration.os
        if run_command('ls /etc/redhat-release')[:exit_status] == 0
          line = run_command('cat /etc/redhat-release')[:stdout]
          if line =~ /release (\d[\d.]*)/
            release = $1
          end
          { :family => 'RedHat', :release => release }
        elsif run_command('ls /etc/system-release')[:exit_status] == 0
          { :family => 'RedHat', :release => nil } # Amazon Linux
        elsif run_command('ls /etc/debian_version')[:exit_status] == 0
          { :family => 'Debian', :release => nil }
        elsif run_command('ls /etc/gentoo-release')[:exit_status] == 0
          { :family => 'Gentoo', :release => nil }
        elsif run_command('ls /usr/lib/setup/Plamo-*')[:exit_status] == 0
          { :family => 'Plamo', :release => nil }
        elsif run_command('uname -s')[:stdout] =~ /AIX/i
          { :family => 'AIX', :release => nil }
        elsif (os = run_command('uname -sr')[:stdout]) && os =~ /SunOS/i
          if os =~ /5.10/
            { :family => 'Solaris10', :release => nil }
          elsif run_command('grep -q "Oracle Solaris 11" /etc/release')[:exit_status] == 0
            { :family => 'Solaris11', :release => nil }
          elsif run_command('grep -q SmartOS /etc/release')[:exit_status] == 0
            { :family => 'SmartOS', :release => nil }
          else
            { :family => 'Solaris', :release => nil }
          end
        elsif run_command('uname -s')[:stdout] =~ /Darwin/i
          { :family => 'Darwin', :release => nil }
        elsif run_command('uname -s')[:stdout] =~ /FreeBSD/i
          { :family => 'FreeBSD', :release => nil }
        else
          { :family => 'Base', :release => nil }
        end
      end
    end
  end
end
