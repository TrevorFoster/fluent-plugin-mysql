# -*- encoding : utf-8 -*-
module Fluent
  class Fluent::MysqlBulkOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('mysql_bulk', self)

    include Fluent::SetTimeKeyMixin

    config_param :host, :string, default: '127.0.0.1',
                 :desc => "Database host."
    config_param :port, :integer, default: 3306,
                 :desc => "Database port."
    config_param :database, :string,
                 :desc => "Database name."
    config_param :username, :string,
                 :desc => "Database user."
    config_param :password, :string, default: '', secret: true,
                 :desc => "Database password."

    config_param :column_names, :string,
                 :desc => "Bulk insert column."
    config_param :key_names, :string, default: nil,
                 :desc => <<-DESC
Value key names, ${time} is placeholder Time.at(time).strftime("%Y-%m-%d %H:%M:%S").
DESC
    config_param :json_key_names, :string, default: nil,
                  :desc => "Key names which store data as json"
    config_param :table, :string,
                 :desc => "Bulk insert table."
    
    config_param :aggregate_data, :bool, default: false,
                 :desc => "Aggregate data enable."
    config_param :aggregate_key_list, :string, default: nil,
                 :desc => "Comma separated list of columns to be used as aggregate key"

    config_param :on_duplicate_key_update, :bool, default: false,
                 :desc => "On duplicate key update enable."
    config_param :on_duplicate_key_operations, :array, default: nil,
                 :desc => "An array of 'column,update_operation' where update_operation is the desired update operation"

    attr_accessor :handler

    def initialize
      super
      require 'mysql2-cs-bind'
    end

    # Define `log` method for v0.10.42 or earlier
    unless method_defined?(:log)
      define_method("log") { $log }
    end

    def configure(conf)
      super

      if @column_names.nil?
        fail Fluent::ConfigError, 'column_names MUST specified, but missing'
      end

      @column_names = @column_names.split(',').collect(&:strip)
      @key_names = @key_names.nil? ? @column_names : @key_names.split(',').collect(&:strip)
      @json_key_names = @json_key_names.split(',') if @json_key_names

      if @on_duplicate_key_update
        if @on_duplicate_key_operations.nil?
          fail Fluent::ConfigError, 'on_duplicate_key_update = true , on_duplicate_key_operations nil!'
        end

        @on_duplicate_key_update_sql = ' ON DUPLICATE KEY UPDATE '

        @on_duplicate_key_indexes = {}
        valid_operations = %w(+ - / * % =)

        operation_statements = []
        @on_duplicate_key_operations.each do |operations_data|
          column_name, operation = operations_data.split(",").collect(&:strip)

          column_index = @column_names.index(column_name)
          next if column_index.nil?

          unless valid_operations.include?(operation)
            fail Fluent::ConfigError, "invalid duplicate key operation supplied for #{column_name}"
          end

          @on_duplicate_key_indexes[column_index] = operation

          operation_statements << "#{column_name} = #{column_name} #{operation} VALUES(#{column_name})"
        end

        @on_duplicate_key_update_sql += operation_statements.join(',')
      end
      
      if @aggregate_data
        if @aggregate_key_list.nil?
          fail Fluent::ConfigError, 'aggregate_data = true , aggregate_key_list nil!'
        end

        @aggregate_column_indexes = @aggregate_key_list.split(",").collect do |column|
          column_index = @column_names.index(column.strip)

          column_index unless column_index.nil?
        end
      end
    end

    def start
      super
      result = client.xquery("SHOW COLUMNS FROM #{@table}")
      @max_lengths = []
      @column_names.each do |column|
        info = result.select { |x| x['Field'] == column }.first
        r = /(char|varchar)\(([\d]+)\)/
        begin
          max_length = info['Type'].scan(r)[0][1].to_i
        rescue
          max_length = nil
        end
        @max_lengths << max_length
      end
    end

    def shutdown
      super
    end

    def format(tag, time, record)
      [tag, time, format_proc.call(tag, time, record)].to_msgpack
    end

    def client
      Mysql2::Client.new(
          host: @host,
          port: @port,
          username: @username,
          password: @password,
          database: @database,
          flags: Mysql2::Client::MULTI_STATEMENTS
        )
    end

    def write(chunk)
      @handler = client

      values_template = "(#{ @column_names.map { |key| '?' }.join(',') })"

      if @unique_indexes.nil?
        values = bind_values(chunk, values_template)
      else
        values = bind_values_aggregate(chunk, values_template)
      end

      sql = "INSERT INTO #{@table} (#{@column_names.join(',')}) VALUES #{values.join(',')}"
      sql += @on_duplicate_key_update_sql if @on_duplicate_key_update

      log.info "bulk insert values size => #{values.size}"
      @handler.xquery(sql)
      @handler.close
    end

    private

    def format_proc
      proc do |tag, time, record|
        values = []
        @key_names.each_with_index do |key, i|
          if key == '${time}'
            value = Time.at(time).strftime('%Y-%m-%d %H:%M:%S')
          else
            if @max_lengths[i].nil? || record[key].nil?
              value = record[key]
            else
              value = record[key].slice(0, @max_lengths[i])
            end

            if @json_key_names && @json_key_names.include?(key)
              value = value.to_json
            end
          end
          values << value
        end
        values
      end
    end

    def bind_values(chunk, values_template)
      values = []

      chunk.msgpack_each do |tag, time, data|
        values << Mysql2::Client.pseudo_bind(values_template, data)
      end

      values
    end

    def bind_values_aggregate(chunk, values_template)
      chunk_aggregate = {}

      chunk.msgpack_each do |tag, time, data|
          aggregate_key = aggregate_column_indexes.collect {|column_index| data[column_index]}.join("|")

          if chunk_aggregate.key?(aggregate_key)
            aggregate_data = chunk_aggregate[aggregate_key]

            data.each_with_index.collect do |item, index|
              if @on_duplicate_key_indexes.key?(index)
                aggregate_data[index] = aggregate_data[index].send(@on_duplicate_key_indexes[index], item)
              end
            end
          else
            chunk_aggregate[aggregate_key] = data
          end
      end

      chunk_aggregate.collect {|_, values| Mysql2::Client.pseudo_bind(values_template, values) }
    end

  end
end
