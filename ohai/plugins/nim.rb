#
# Author:: Jez Wain (<jez.wain@us.ibm.com>)
#
# Copyright:: 2016, IBM
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

Ohai.plugin(:NIM) do
  provides 'nim'

  # parse_niminfo
  #
  # Parses /etc/niminfo file, transforming the key-value pairs into a hash
  # If run on a nim master it will also parse the niminfo file on each client
  # and provide details of known lpp_sources
  #
  #
  # == Parameters:
  # niminfo_file::
  #   String: The full path to the niminfo file, defaults to /etc/niminfo.
  #
  # == Returns:
  #   Hash: Key/Value pairs for each nim attribute defined in the niminfo file
  #         When run on the nim master the hash contains values for all known clients
  #         and all known lpp_sources
  #
  def parse_niminfo(niminfo_file = '/etc/niminfo')
    niminfo = {}
    niminfo_hash = File.open(niminfo_file) do |info|
      niminfo_to_hash(info)
    end
    niminfo['master'] = niminfo_hash
    oslevel = shell_out('/usr/bin/oslevel -s').stdout.chomp
    niminfo['master']['oslevel'] = oslevel

    if master? niminfo
      niminfo['clients'] = clients
      niminfo['lpp_sources'] = lpp_sources
      niminfo['spots'] = spots
      niminfo['vioses'] = vioses
    end
    niminfo
  end

  class ::Hash
    def deep_merge(second)
      merger = proc { |_key, v1, v2| Hash == v1 && Hash == v2 ? v1.merge(v2, &merger) : v2 }
      merge(second, &merger)
    end
  end

  # clients
  #
  # Determines if the niminfo configuration and oslevel for all the clients of a nim master
  #
  # Note: The oslevel command adds considerably to the execution time of the ohai plugin.
  #
  # == Parameters:
  #   none
  #
  # == Returns:
  #   Hash of Hashes: Hash with nim client name as key, niminfo hash as the value
  #                   Also includes the oslevel
  #
  def clients
    c_rsh = '/usr/lpp/bos.sysmgt/nim/methods/c_rsh'
    threads = []
    shell_out('/usr/sbin/lsnim -t standalone').stdout.each_line do |line|
      client_name = line.split.first
      threads.push(Thread.new do
        begin
          ret = {}
          cmd_rc = shell_out("#{c_rsh} #{client_name} \"cat /etc/niminfo\"", timeout: 30).stdout
          ret[client_name] = niminfo_to_hash(cmd_rc)
          oslevel = shell_out("#{c_rsh} #{client_name} \"/usr/bin/oslevel -s\"", timeout: 30).stdout.chomp
          ret[client_name]['oslevel'] = oslevel
          client_attributes = nim_attr_string_to_hash(shell_out("/usr/sbin/lsnim -l #{client_name}").stdout)
          purge_superfluous_attributes(client_attributes)
          ret[client_name]['lsnim'] = client_attributes
        rescue Ohai::Exceptions::Exec => e
          if e.message.end_with?('returned 2')
            $stderr.puts "#{client_name} timed out"
          else
            $stderr.puts "#{client_name}: #{e.message}"
          end
        rescue StandardError => e
          $stderr.puts "#{client_name} error: #{e.class.name}"
          puts e.message
        end
        ret
      end)
    end
    clients = {}
    threads.each { |thr| clients = clients.deep_merge(thr.value) }
    clients.sort_by { |k, _v| k }.to_h
  end

  # lpp_sources
  #
  # Identifies the lpp_sources available to a nim master
  #
  # == Parameters:
  #   none
  #
  # == Returns:
  #   Hash of Hashes: Hash with nim lpp_source resource name as key, with a hash of
  #   attributes of each lpp_source as the value
  #
  def lpp_sources
    threads = []
    shell_out('/usr/sbin/lsnim -t lpp_source').stdout.each_line do |line|
      threads.push(Thread.new do
        ret = {}
        lpp_source = line.split.first
        lpp_source_attributes = nim_attr_string_to_hash(shell_out("/usr/sbin/lsnim -l #{lpp_source}").stdout)
        purge_superfluous_attributes(lpp_source_attributes)
        ret[lpp_source] = lpp_source_attributes
        ret
      end)
    end
    lpp_sources = {}
    threads.each { |thr| lpp_sources.merge!(thr.value) }
    lpp_sources
  end

  # spots
  #
  # Identifies the spots available to a nim master
  #
  # == Parameters:
  #   none
  #
  # == Returns:
  #   Hash of Hashes: Hash with nim spot name as key, with a hash of
  #   attributes of each spot as the value
  #
  def spots
    threads = []
    shell_out('/usr/sbin/lsnim -t spot').stdout.each_line do |line|
      threads.push(Thread.new do
        ret = {}
        spot = line.split.first
        spot_attributes = nim_attr_string_to_hash(shell_out("/usr/sbin/lsnim -l #{spot}").stdout)
        purge_superfluous_attributes(spot_attributes)
        ret[spot] = spot_attributes
        ret
      end)
    end
    spots = {}
    threads.each { |thr| spots.merge!(thr.value) }
    spots
  end

  # vioses
  #
  # Identifies the VIOS's available to a nim master
  #
  # == Parameters:
  #   none
  #
  # == Returns:
  #   Hash of Hashes: Hash with nim vios resource name as key, with a hash of
  #   attributes of each vios as the value
  #
  def vioses
    threads = []
    shell_out('/usr/sbin/lsnim -t vios').stdout.each_line do |line|
      threads.push(Thread.new do
        ret = {}
        vios = line.split.first
        vios_attributes = nim_attr_string_to_hash(shell_out("/usr/sbin/lsnim -l #{vios}").stdout)
        purge_superfluous_attributes(vios_attributes)
        ret[vios] = vios_attributes
        ret
      end)
    end
    vioses = {}
    threads.each { |thr| vioses.merge!(thr.value) }
    vioses
  end

  # niminfo_to_hash
  #
  # Parses a /etc/niminfo stream/string, transforming the key-value pairs into a hash
  # Each (non-comment) line has the following format
  # export NIM_NAME=host
  # export NIM_HOSTNAME=fully.qualified.host.name
  # ...
  #
  #
  # == Parameters:
  # niminfo_stream::
  #   String/Stream: Any object that supports .each_line returning a string
  #
  # == Returns:
  #   Hash: Key/Value pairs for each nim attribute defined in the niminfo file
  #
  def niminfo_to_hash(string)
    hash = {}
    string.each_line do |line|
      line.chomp!
      # parse the key and value, each side of the '='
      next unless line =~ /^export\s+([[[:upper:]]_]+)=(.+)/
      key = Regexp.last_match(1)
      value = Regexp.last_match(2)
      # normalise the key & remove quotes from value
      key.gsub!(/NIM_/, '')
      key.downcase!
      value.delete!('"')
      # Hosts, routes and mounts are space-separated lists
      value = value.split if key =~ /hosts|routes|mounts/
      hash[key] = value
    end
    hash
  end

  # master?
  #
  # Determines if the niminfo configuration is for a master or not
  #
  #
  # == Parameters:
  # nim::
  #   Hash: niminfo hash
  #
  # == Returns:
  #   Boolean: True if on nim master, otherwise false
  #
  def master?(nim)
    nim['master']['configuration'] == 'master'
  end

  # nim_attr_string_to_hash
  #
  # Parses a string of nim key/value attributes and returns the hash equivalent
  #
  # == Parameters:
  #   String:: nim attribute string
  #
  # == Returns:
  #   Hash:: nim attribute hash
  #
  def nim_attr_string_to_hash(string)
    hash = {}
    string.each_line do |line|
      if line.start_with?(' ')
        key, value = line.split(/=/)
        hash[key.to_s.strip] = value.to_s.strip
      end
    end
    hash
  end

  # purge_superfluous_attributes
  #
  def purge_superfluous_attributes(hash)
    %w(class type arch prev_state simages bos_license name).each do |attr|
      hash.delete attr
    end
  end

  # collect_data
  #
  # Primary entry point to the ohai plugin.
  #
  # == Parameters:
  #   Symbol:: :aix - NIM is only available on AIX
  #
  # == Returns:
  #   Hash:: Hash of nim attributes. When run on the nim master also contains the nim
  #   attributes of each client.
  #
  collect_data(:aix) do
    nim {}
    parse_niminfo.each_pair do |key, value|
      nim[key] = value
    end
    nim
  end
end
