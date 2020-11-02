require 'date'
require 'oink/reports/base'
require 'oink/reports/memory_oinked_request'
require 'oink/reports/priority_queue'
require 'gruff'

module Oink
  module Reports
    class MemoryUsageReport < Base
      def print(output)
        @chart = nil
        if @format == :graphed
          @chart = Gruff::StackedBar.new
          @chart.title='Bad Actions'
        end

        oink_entry_count = 0
        output.puts "---- MEMORY THRESHOLD ----"
        output.puts "THRESHOLD: #{@threshold/1024} MB\n"

        output.puts "\n-- REQUESTS --\n" if @format == :verbose

        @inputs.each do |input|
          input.each_line do |line|
            line = line.strip

             # Skip this line since we're only interested in the Hodel 3000 compliant lines
            next unless line =~ HODEL_LOG_FORMAT_REGEX
            pid = extract_pid_from_line(line, @pids)


            if line =~ /Oink Action: (([\w\/]+)#(\w+))/
              record_action($1, pid, @pids)

            elsif line =~ /Memory usage: (\d+) /

              memory_reading = $1.to_i
              record_memory_usage(memory_reading, pid, @pids)

            elsif line =~ /Oink Log Entry Complete/

              oink_entry_count += 1
              complete_entry(line,
                             pid,
                             @pids,
                             output,
                             @threshold,
                             @bad_actions,
                             @bad_actions_averaged,
                             @bad_requests,
                             @format)

            end # end elsif
          end # end each_line
        end # end each input

        output.puts "---- Oink Entries Parsed: #{oink_entry_count} ----\n" if @format == :verbose
        print_summary(output)

        generate_graph() if @format == :graphed
      end

      private
      
      def extract_pid_from_line(line, pids)
        if line =~ /rails\[(\d+)\]/
          pid = $1
          pids[pid] ||= { :buffer => [], :last_memory_reading => -1, :current_memory_reading => -1, :action => "", :request_finished => true }
          pids[pid][:buffer] << line
          return pid
        end
        nil
      end

      def record_action(action, pid, pids)
        unless pids[pid][:request_finished]
          pids[pid][:last_memory_reading] = -1
        end
        pids[pid][:action] = action
        pids[pid][:request_finished] = false
      end

      def record_memory_usage(memory_reading, pid, pids)
        pids[pid][:current_memory_reading] = memory_reading
      end

      # TODO: refactor to not require a bajillion params
      def complete_entry(line,
                         pid,
                         pids,
                         output,
                         threshold,
                         bad_actions,
                         bad_actions_averaged,
                         bad_requests,
                         format)
        pids[pid][:request_finished] = true
        # setup some vars for simplification

        current_memory_reading = pids[pid][:current_memory_reading]
        last_memory_reading = pids[pid][:last_memory_reading]
        buffer = pids[pid][:buffer]

        # process
        unless current_memory_reading == -1 || last_memory_reading == -1
          memory_diff = current_memory_reading - last_memory_reading

          if memory_diff > threshold
            action = pids[pid][:action]
            bad_actions[action] ||= 0
            bad_actions[action] += 1
            date = HODEL_LOG_FORMAT_REGEX.match(line).captures[0]
            bad_requests.push(MemoryOinkedRequest.new(action, date, buffer, memory_diff))
            if format == :verbose
              buffer.each { |b| output.puts b }
              output.puts "---------------------------------------------------------------------"
            end
            bad_actions_averaged[action] ||= []
            bad_actions_averaged[action] << memory_diff
          end
        end

        pids[pid][:buffer] = []
        pids[pid][:last_memory_reading] = current_memory_reading
        pids[pid][:current_memory_reading] = -1
      end

      def generate_graph
        graph_filename='oink_memory_usage.png'
        begin
          labels = []
          action_stats = calculate_action_stats(@bad_actions_averaged)
          mins= []
          maxes=[]
          action_stats
            .sort_by{ |x| x[:action]}
            .each do | action_hash |
              labels << action_hash[:action]
              mins << action_hash[:min]
              maxes << action_hash[:max]
            end
          labels_hash = {}
          (0...labels.size).each do |idx|
           labels_hash[idx] = labels[idx]
          end

          @chart.data('minimum', mins)
          @chart.data('maximum', maxes)
          @chart.labels = labels_hash

          @chart.labels = Hash[*((0...labels.size).zip((0..labels.size)).flatten)]
          puts "\nGraph Key:"
          labels_hash.each do |k,v|
            puts "#{k}: #{v}"
          end

          @chart.write(graph_filename)
          puts "\nWrote graph to #{graph_filename}"
        rescue StandardError => e
          puts "error writing graph file #{graph_filename}: #{e.message}"
        end
      end
    end

  end
end
