Ohai.plugin(:NIM) do
  provides "nim"

  collect_data(:aix) do
    nim Mash.new

      File.open('/etc/niminfo').each_line do |nim_info|
        nim_info.each_line do |line|
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
            value.gsub!(/\"/, '')

            # Hosts, routes and mounts are space-separated lists
            if key =~ /hosts|routes|mounts/ then
              value = value.split
            end
            nim[key] = value
          end
        end
      end

    nim
  end


end