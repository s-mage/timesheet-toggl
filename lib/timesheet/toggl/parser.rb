module Timesheet
  # get issue id
  #   issue-related params
  # get project
  # split by several issues
  #   if one issue, then all good
  #   if several:
  #     delete time entries from timesheet
  #     delete time entries from kibana
  #     add new time entries to timesheet
  # @time_part
  #
  class TogglRecord
    attr_accessor :record, :config, :time_entry_class
    Time.zone = 'UTC' # not to corrupt start_time and end_time

    def initialize(hash, config)
      @descriptions = parse_description hash[:description]
      @record = hash
      @config = config
      return unless tec = config[:redmine_time_entry_class]
      @time_entry_class = Kernel.const_get tec
    end

    def parse_description(description)
      result = description.scan(/(#\s?\S+[^#]+)/).flatten
      result.size < 2 ? [description] : result
    end

    def push
      return unless params = descriptions_params
      if params.size > 1
        TimeEntry.recreate(record[:id], config[:source_id], params)
      else
        TimeEntry.create_or_update(record[:id], config[:source_id], params.first)
      end
    end

    def descriptions_params
      return unless params = common_params
      descriptions_with_hours(params[:hours]).map do |k, v|
        params_with_comment = params.merge(comment: k, hours: v)
        params_with_comment.merge(issue_related_params(params_with_comment))
      end
    end

    # description without @hours gets 1/n of all time, where n is count of descriptions.
    #
    def descriptions_with_hours(total_hours)
      d = descriptions_with_time_parts
      times = d.values.reject(&:zero?)
      if times.empty?
        one_part = 0
      else
        one_part = (times.size / d.size.to_f) * total_hours / times.inject(&:+)
      end
      d.inject({}) do |r, (k, v)|
        r.merge(k => (v.zero? ? (total_hours / d.size) : (one_part * v)))
      end
    end

    def descriptions_with_time_parts
      @descriptions.inject({}) do |r, x|
        r.merge(x => time_parts(x))
      end
    end

    def time_parts(description)
      description.scan(/@\s?(\d+)/).flatten.first.to_i
    end

    def common_params
      return unless uid = user_id
      p = map_params.merge(user_id: uid)
      p.merge derived_params(p)
    end

    def derived_params(params)
      {
        data_source_id: config[:source_id],
        spent_on: record[:start],
        hours: params[:hours] / 3_600_000.0,
        client_id: params[:client_id] || client_id
      }
    end

    def map_params
      record.reduce({}) do |r, (k, v)|
        next(r) unless x = params_map[k]
        r.merge(x => v)
      end
    end

    def params_map
      {
        id: :external_id,
        project: :project,
        description: :comment,
        dur: :hours,
        start: :start_time,
        end: :finish_time
      }
    end

    def issue_related_params(params)
      if iid = issue_id(params)
        p iid
        return {} unless time_entry_class = DataSource.time_entry_class(iid)
        time_entry_class.issue_related_params(iid)
      elsif pname = project_name(params)
        normalized_pname = pname.underscore.gsub(/[^a-zA-z]/, '_')
        client_name = client_name_by_project normalized_pname
        return {} unless client_name
        { project: denormalize_project_name(normalized_pname),
          client_id: client_id(client_name) }
      elsif pname = record[:project]
        { project: pname, client_id: client_id }
      else
        {}
      end
    end

    def client_name_by_project(pname)
      hash = config[:projects].find { |x| x[:project] == pname }
      hash ? hash[:client] : TimeEntryConnector.company_by_project_name(pname)
    end

    def denormalize_project_name(normalized)
      config[:projects].find { |x| x[:project] == normalized }.try(:[], :project_origin) ||
        TimeEntryConnector.denormalize_project_name(normalized)
    end

    def project_name(params)
      params[:comment].match(/#\s?(\S+)/).try(:[], 1)
    end

    def issue_id(params)
      return unless time_entry_class
      params[:comment].match(/#\s?(\d+)/).try(:[], 1).try(:to_i)
    end

    def client_id(name = nil)
      Client.id_by_name (name || record[:client])
    end

    def user_id
      DataSourceUser.user_id_for config[:source_id], record[:uid]
    end
  end
end
