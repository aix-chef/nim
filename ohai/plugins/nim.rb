Ohai.plugin(:NIM) do
  provides "nim"


  def parse_niminfo
    niminfo = File.open('/etc/niminfo') do |niminfo|
      niminfo_to_hash(niminfo)
    end

    if is_master? niminfo then
      niminfo['clients'] = clients
      niminfo['lpp_sources'] = lpp_sources
    end

    niminfo
  end


  def niminfo_to_hash(niminfo_stream)

    nim_hash = Hash.new

    niminfo_stream.each_line do |line|
      line.chomp!

      # Each (non-comment) line has the following format
      # export NIM_NAME=regency2c03
      # export NIM_HOSTNAME=regency2c03.aus.stglabs.ibm.com
      # ...
      # parse the key and value, each side of the '='
      if line =~ /^export\s+([[[:upper:]]_]+)=(.+)/ then
        key, value = $1, $2

        # normalise the key & remove quotes from value
        key.gsub!(/NIM_/, '')
        key.downcase!
        value.gsub!(/"/, '')

        # Hosts, routes and mounts are space-separated lists
        if key =~ /hosts|routes|mounts/ then
          value = value.split
        end
        nim_hash[key] = value
      end
    end

    nim_hash
  end

  def is_master?(nim)
    nim['configuration'] == 'master'
  end

  def clients
    clients = Hash.new
    client_list = shell_out('/usr/sbin/lsnim -t standalone').stdout
    client_list.each_line do |line|
      client_name = line.split[0]

      client_niminfo =
        shell_out("/usr/lpp/bos.sysmgt/nim/methods/c_rsh #{client_name} \"cat /etc/niminfo\"").stdout

      client_niminfo = niminfo_to_hash(client_niminfo)
      clients[client_name] = client_niminfo
    end
    clients
  end

  def lpp_sources
    lpp_sources = Hash.new()
    shell_out('/usr/sbin/lsnim -t lpp_source').stdout.each_line do |line|
      lpp_source = line.split[0]
      lpp_source_attributes = lpp_source_to_hash(shell_out("/usr/sbin/lsnim -l #{lpp_source}").stdout)
      lpp_sources[lpp_source] = lpp_source_attributes
    end

    lpp_sources
  end

  def lpp_source_to_hash(lpp_source_stream)
    lpp_source_attributes = Hash.new
    lpp_source_stream.each_line do |line|
      if line =~ /^\s+/ then
        line.strip!
        key, value = line.split(/=/)
        lpp_source_attributes[key] = value
      end
    end
    lpp_source_attributes
  end

  collect_data(:aix) do
    nim Hash.new

    parse_niminfo.each_pair do |key, value|
      nim[key] = value
    end

    nim
  end

end
