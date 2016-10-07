# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2016, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER, THE UNITED STATES
# GOVERNMENT, OR ANY CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

# Command line based interface to execute the Workflow manager.

# ruby worker_init_final.rb -h localhost:3000 -a 330f3f4a-dbc0-469f-b888-a15a85ddd5b4 -s initialize
# ruby simulate_data_point.rb -h localhost:3000 -a 330f3f4a-dbc0-469f-b888-a15a85ddd5b4 -u 1364e270-2841-407d-a495-cf127fa7d1b8

class RunSimulateDataPoint
  def initialize(data_point_id, options = {})
    defaults = { run_workflow_method: 'workflow' }.with_indifferent_access
    @options = defaults.deep_merge(options)

    @data_point = DataPoint.find(data_point_id)

    # For now just track the status here. Ideally we would use delayed jobs
    # or a plugin for delayed jobs to track the status of the job.

    # Also, should we use the API to set these or relay on mongoid?
    @data_point.update(run_queue_time: Time.now, status: 'queued')
    @data_point.save!
  end

  def perform
    if @data_point.nil?
      status_message = 'Could not find datapoint'
      return
    end

    @data_point.update(run_start_time: Time.now, status: 'started')

    # Create the analysis directory
    FileUtils.mkdir_p analysis_dir unless Dir.exist? analysis_dir
    FileUtils.mkdir_p simulation_dir unless Dir.exist? simulation_dir

    @data_point.update(status: 'started')

    # Logger for the simulate datapoint
    sim_logger = Logger.new("#{simulation_dir}/#{@data_point.id}.log")

    sim_logger.info "Server host is #{APP_CONFIG['os_server_host_url']}"
    sim_logger.info "Analysis directory is #{analysis_dir}"
    sim_logger.info "Simulation directory is #{simulation_dir}"
    sim_logger.info "Run datapoint type/file is #{@options[:run_workflow_method]}"

    initialize_worker(sim_logger)

    # delete any existing data files from the server in case this is a 'rerun'
    RestClient.delete "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}/result_files"

    # Download the datapoint to run and save to disk
    url = "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}.json"
    sim_logger.info "Downloading datapoint from #{url}"
    r = RestClient.get url
    raise 'Analysis JSON could not be downloaded' unless r.code == 200
    # Parse to JSON to save it again with nice formatting
    File.open("#{simulation_dir}/data_point.json", 'w') { |f| f << JSON.pretty_generate(JSON.parse(r)) }

    # copy over the test file to the run directory
    FileUtils.cp "#{analysis_dir}/analysis.json", "#{simulation_dir}/analysis.json"

    osw_path = "#{simulation_dir}/data_point.osw"
    osw_options = {
      file_paths: [
        '../weather',
        '../seed'
      ],
      measure_paths: ['../measures']
    }
    t = OpenStudio::Analysis::Translator::Workflow.new(
      "#{simulation_dir}/analysis.json",
      osw_options
    )
    t_result = t.process_datapoint("#{simulation_dir}/data_point.json")
    if t_result
      File.open(osw_path, 'w') { |f| f << JSON.pretty_generate(t_result) }
    else
      raise 'Could not translate OSA, OSD into OSW'
    end

    sim_logger.info 'Creating Workflow Manager instance'
    sim_logger.info "Directory is #{simulation_dir}"

    adapter_options = {
      workflow_filename: File.basename(osw_path),
      datapoint_filename: "#{simulation_dir}/data_point.json",
      analysis_filename: "#{analysis_dir}/analysis.json"
    }

    run_options = { debug: true, cleanup: false }

    k = OpenStudio::Workflow::Run.new osw_path, run_options
    sim_logger.info 'Running workflow'
    k.run
    sim_logger.info "Final run state is #{k.current_state}"

    # Save the results to the database - i was PUTing these to the server,
    # but the values were not be typed correctly within RestClient.
    results_file = "#{simulation_dir}/run/measure_attributes.json"
    if File.exist? results_file
      results = JSON.parse(File.read(results_file), symbolize_names: true)

      # push the results to the server
      # DLM: TODO make this a RESTful call instead of Mongoid
      @data_point.update(results: results)

      # TODO: Need to create a chord to run at the end of all the datapoints to finalize the analysis
    else
      raise "Could not find results #{results_file}"
    end

    sim_logger.info 'Saving files/reports back to the server'

    # Post the reports back to the server
    # TODO: check for timeouts and retry
    Dir["#{simulation_dir}/reports/*.{html,json,csv}"].each do |report|
      url = "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}/upload_file"
      sim_logger.info "Saving report #{report} to #{url}"
      RestClient.post(url, file: { display_name: File.basename(report, '.*'),
                                   type: 'Report',
                                   attachment: File.new(report, 'rb') })
    end

    report_file = "#{simulation_dir}/run/objectives.json"
    if File.exist? report_file
      url = "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}/upload_file"
      sim_logger.info "Saving report #{report_file} to #{url}"
      RestClient.post(url, file: { display_name: File.basename(report_file, '.*'),
                                   type: 'Report',
                                   attachment: File.new(report_file, 'rb') })
    end

    report_file = "#{simulation_dir}/out.osw"
    if File.exist? report_file
      url = "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}/upload_file"
      sim_logger.info "Saving report #{report_file} to #{url}"
      RestClient.post(url,
                      file: {
                        display_name: File.basename(report_file, '.*'),
                        type: 'Report',
                        attachment: File.new(report_file, 'rb')
                      },
                      content_type: 'application/json')
    end

    # Post the zip file of results
    # TODO: Do not save the _reports file anymore in the workflow gem
    results_zip = "#{simulation_dir}/data_point.zip"
    if File.exist? results_zip
      url = "#{APP_CONFIG['os_server_host_url']}/data_points/#{@data_point.id}/upload_file"
      sim_logger.info "Saving zip #{results_zip} to #{url}"
      RestClient.post(url, file: { display_name: 'Zip File',
                                   type: 'Data Point',
                                   attachment: File.new(results_zip, 'rb') })
    end

    @data_point.update(status_message: 'completed normal')
  rescue => e
    log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
    puts log_message
    sim_logger.info log_message if sim_logger
    @data_point.update(status_message: 'error')
  ensure
    sim_logger.info "Finished #{__FILE__}" if sim_logger
    sim_logger.close if sim_logger

    @data_point.update(run_end_time: Time.now, status: 'completed') if @data_point

    true
  end

  # Method to download and unzip the analysis data. This has some logic
  # in order to handle multiple instances trying to download the file at the
  # same time.
  def initialize_worker(sim_logger)
    sim_logger.info "Starting download analysis zip for datapoint #{@data_point.id}"

    # If the request is local, then just copy the data over. But how do we
    # test if the request is local?
    write_lock_file = "#{analysis_dir}/analysis_zip.lock"
    receipt_file = "#{analysis_dir}/analysis_zip.receipt"

    # Check if the receipt file exists, if so, then just return out of this
    # method immediately
    return true if File.exist? receipt_file

    # only call this block if there is no write_lock nor receipt in the dir
    if File.exist? write_lock_file
      # wait until receipt file appears then return
      loop do
        break if File.exist? receipt_file
        sleep 1
      end

      return true
    else
      # download the file, but first create the write lock
      write_lock(write_lock_file) do |_|
        # create write lock
        download_file = "#{analysis_dir}/analysis.zip"
        download_url = "#{APP_CONFIG['os_server_host_url']}/analyses/#{@data_point.analysis.id}/download_analysis_zip"
        sim_logger.info "Downloading analysis zip from #{download_url}"

        File.open(download_file, 'wb') do |saved_file|
          # the following "open" is provided by open-uri
          open(download_url, 'rb') do |read_file|
            saved_file.write(read_file.read)
          end
        end

        # Extract the zip
        OpenStudio::Workflow.extract_archive(download_file, analysis_dir)

        # Download only one copy of the analysis.json # http://localhost:3000/analyses/6adb98a1-a8b0-41d0-a5aa-9a4c6ec2bc79.json
        a = RestClient.get "#{APP_CONFIG['os_server_host_url']}/analyses/#{@data_point.analysis.id}.json"
        raise 'Analysis JSON could not be downloaded' unless a.code == 200
        # Parse to JSON to save it again with nice formatting
        File.open("#{analysis_dir}/analysis.json", 'w') { |f| f << JSON.pretty_generate(JSON.parse(a)) }

        # Find any custom worker files -- should we just call these via system ruby? Then we could have any gem that is installed (not bundled)
        files = Dir["#{analysis_dir}/lib/worker_initialize/*.rb"].map { |n| File.basename(n) }.sort
        sim_logger.info "The following custom worker initialize files were found #{files}"
        files.each do |f|
          run_file(analysis_dir, 'initialize', f, sim_logger)
        end
      end

      # Now tell all other waiting threads that it is okay to continue
      # by creating the receipt file.
      File.open(receipt_file, 'w') { |f| f << Time.now }
    end

    sim_logger.info 'Finished worker initialization'
    true
  end

  # Finalize the worker node by running the scripts
  def finalize_worker(sim_logger)
  end

  # Simple method to write a lock file in order for competing threads to
  # wait until this operation is complete before continuing.
  def write_lock(lock_file_path)
    lock_file = File.open(lock_file_path, 'a')
    begin
      lock_file.flock(File::LOCK_EX)
      lock_file << Time.now

      yield
    ensure
      lock_file.flock(File::LOCK_UN)
    end
  end

  private

  def analysis_dir
    "#{APP_CONFIG['sim_root_path']}/analysis_#{@data_point.analysis.id}"
  end

  def simulation_dir
    "#{analysis_dir}/data_point_#{@data_point.id}"
  end

  # Return the logger for delayed jobs which is typically rails_root/log/delayed_job.log
  def logger
    Delayed::Worker.logger
  end

  # Run the initialize/finalize scripts
  def run_file(analysis_dir, state, file, sim_logger)
    f_fullpath = "#{analysis_dir}/lib/worker_#{state}/#{file}"
    f_argspath = "#{File.dirname(f_fullpath)}/#{File.basename(f_fullpath, '.*')}.args"
    sim_logger.info "Running #{state} script #{f_fullpath}"

    # Each worker script has a very specific format and should be loaded and run as a class
    require f_fullpath

    # Remove the digits that specify the order and then create the class name
    klass_name = File.basename(f, '.*').gsub(/^\d*_/, '').split('_').map(&:capitalize).join

    # instantiate a class
    klass = Object.const_get(klass_name).new

    # check if there is an argument json that accompanies the class
    args = nil
    sim_logger.info "Looking for argument file #{f_argspath}"
    if File.exist?(f_argspath)
      sim_logger.info "argument file exists #{f_argspath}"
      args = eval(File.read(f_argspath))
      sim_logger.info "arguments are #{args}"
    end

    r = klass.run(*args)
    sim_logger.info "Script returned with #{r}"

    klass.finalize if klass.respond_to? :finalize
  end
end