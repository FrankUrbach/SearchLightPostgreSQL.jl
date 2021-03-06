module SearchLightPostgreSQL

import LibPQ, DataFrames, Logging
import SearchLight


#
# Setup
#


const DEFAULT_PORT = 5432

const COLUMN_NAME_FIELD_NAME = :column_name

function SearchLight.column_field_name()
  COLUMN_NAME_FIELD_NAME
end

const DatabaseHandle = LibPQ.Connection
const ResultHandle   = LibPQ.Result

const TYPE_MAPPINGS = Dict{Symbol,Symbol}( # Julia / Postgres
  :char       => :CHARACTER,
  :string     => :VARCHAR,
  :text       => :TEXT,
  :integer    => :INTEGER,
  :int        => :INTEGER,
  :float      => :FLOAT,
  :decimal    => :DECIMAL,
  :datetime   => :DATETIME,
  :timestamp  => :INTEGER,
  :time       => :TIME,
  :date       => :DATE,
  :binary     => :BLOB,
  :boolean    => :BOOLEAN,
  :bool       => :BOOLEAN
)

const CONNECTIONS = DatabaseHandle[]

#
# Connection
#


"""
    connect(conn_data::Dict)::DatabaseHandle

Connects to the database and returns a handle.
"""
function SearchLight.connect(conn_data::Dict = SearchLight.config.db_config_settings) :: DatabaseHandle
  dns = String[]

  haskey(conn_data, "host")     && push!(dns, string("host=", conn_data["host"]))
  haskey(conn_data, "hostaddr") && push!(dns, string("hostaddr=", conn_data["hostaddr"]))
  haskey(conn_data, "port")     && push!(dns, string("port=", conn_data["port"]))
  haskey(conn_data, "database") && push!(dns, string("dbname=", conn_data["database"]))
  haskey(conn_data, "username") && push!(dns, string("user=", conn_data["username"]))
  haskey(conn_data, "password") && push!(dns, string("password=", conn_data["password"]))
  haskey(conn_data, "passfile") && push!(dns, string("passfile=", conn_data["passfile"]))
  haskey(conn_data, "connect_timeout") && push!(dns, string("connect_timeout=", conn_data["connect_timeout"]))
  haskey(conn_data, "client_encoding") && push!(dns, string("client_encoding=", conn_data["client_encoding"]))

  push!(CONNECTIONS, LibPQ.Connection(join(dns, " ")))[end]
end


"""
    disconnect(conn::DatabaseHandle)::Nothing

Disconnects from database.
"""
function SearchLight.disconnect(conn::DatabaseHandle = SearchLight.connection()) :: Nothing
  LibPQ.close(conn)
end


function SearchLight.connection()
  isempty(CONNECTIONS) && throw(SearchLight.Exceptions.NotConnectedException())

  CONNECTIONS[end]
end


#
# Utility
#


"""
    columns{T<:AbstractModel}(m::Type{T})::DataFrames.DataFrame
    columns{T<:AbstractModel}(m::T)::DataFrames.DataFrame

Returns a DataFrame representing schema information for the database table columns associated with `m`.
"""
function SearchLight.columns(m::Type{T})::DataFrames.DataFrame where {T<:SearchLight.AbstractModel}
  SearchLight.query(table_columns_sql(SearchLight.table(m)), internal = true)
end


"""
    table_columns_sql(table_name::String)::String

Returns the adapter specific query for SELECTing table columns information corresponding to `table_name`.
"""
function table_columns_sql(table_name::String) :: String
  "SELECT column_name FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = '$table_name'"
end


#
# Data sanitization
#


"""
    escape_column_name(c::String, conn::DatabaseHandle)::String

Escapes the column name.

# Examples
```julia
julia>
```
"""
function SearchLight.escape_column_name(c::String, conn::DatabaseHandle = SearchLight.connection()) :: String
  join(["""\"$(replace(cx, "\""=>"'"))\"""" for cx in split(c, '.')], '.')
end


"""
    escape_value{T}(v::T, conn::DatabaseHandle)::T

Escapes the value `v` using native features provided by the database backend if available.

# Examples
```julia
julia>
```
"""
function SearchLight.escape_value(v::T, conn::DatabaseHandle = SearchLight.connection())::T where {T}
  isa(v, Number) ? v : "E'$(replace(string(v), "'"=>"\\'"))'"
end


#
# Query execution
#


function SearchLight.query(sql::String, conn::DatabaseHandle = SearchLight.connection(); internal = false) :: DataFrames.DataFrame
  result = if SearchLight.config.log_queries && ! internal
    @info sql
    @time LibPQ.execute(conn, sql)
  else
    LibPQ.execute(conn, sql)
  end

  if LibPQ.error_message(result) != ""
    throw(SearchLight.Exceptions.DatabaseAdapterException("$(string(LibPQ)) error: $(LibPQ.errstring(result)) [$(LibPQ.errcode(result))]"))
  end

  result |> DataFrames.DataFrame
end


function SearchLight.to_find_sql(m::Type{T}, q::SearchLight.SQLQuery, joins::Union{Nothing,Vector{SearchLight.SQLJoin{N}}} = nothing)::String where {T<:SearchLight.AbstractModel, N<:Union{Nothing,SearchLight.AbstractModel}}
  sql::String = ( string("$(SearchLight.to_select_part(m, q.columns, joins)) $(SearchLight.to_from_part(m)) $(SearchLight.to_join_part(m, joins)) $(SearchLight.to_where_part(q.where)) ",
                      "$(SearchLight.to_group_part(q.group)) $(SearchLight.to_having_part(q.having)) $(SearchLight.to_order_part(m, q.order)) ",
                      "$(SearchLight.to_limit_part(q.limit)) $(SearchLight.to_offset_part(q.offset))")) |> strip
  replace(sql, r"\s+"=>" ")
end


function SearchLight.to_store_sql(m::T; conflict_strategy = :error)::String where {T<:SearchLight.AbstractModel}
  uf = SearchLight.persistable_fields(typeof(m))

  sql = if ! SearchLight.ispersisted(m) || (SearchLight.ispersisted(m) && conflict_strategy == :update)
    pos = findfirst(x -> x == SearchLight.primary_key_name(m), uf)
    pos > 0 && splice!(uf, pos)

    fields = SearchLight.SQLColumn(uf)
    vals = join( map(x -> string(SearchLight.to_sqlinput(m, Symbol(x), getfield(m, Symbol(x)))), uf), ", ")

    "INSERT INTO $(SearchLight.table(typeof(m))) ( $fields ) VALUES ( $vals )" *
        if ( conflict_strategy == :error ) ""
        elseif ( conflict_strategy == :ignore ) " ON CONFLICT DO NOTHING"
        elseif ( conflict_strategy == :update &&
          getfield(m, Symbol(SearchLight.primary_key_name(m))).value !== nothing )
            " ON CONFLICT ($(SearchLight.primary_key_name(m))) DO UPDATE SET $(SearchLight.update_query_part(m))"
        else ""
        end
  else
    "UPDATE $(SearchLight.table(typeof(m))) SET $(SearchLight.update_query_part(m))"
  end

  return string(sql, " RETURNING $(SearchLight.primary_key_name(m))")
end


function SearchLight.delete_all(m::Type{T}; truncate::Bool = true, reset_sequence::Bool = true, cascade::Bool = false)::Nothing where {T<:SearchLight.AbstractModel}
  if truncate
    sql = "TRUNCATE $(SearchLight.table(m))"
    reset_sequence ? sql *= " RESTART IDENTITY" : ""
    cascade ? sql *= " CASCADE" : ""
  else
    sql = "DELETE FROM $(SearchLight.table(m))"
  end

  SearchLight.query(sql)

  nothing
end


function SearchLight.delete(m::T)::T where {T<:SearchLight.AbstractModel}
  SearchLight.ispersisted(m) || throw(SearchLight.Exceptions.NotPersistedException(m))

  "DELETE FROM $(SearchLight.table(typeof(m))) WHERE $(SearchLight.primary_key_name(typeof(m))) = '$(m.id.value)'" |> SearchLight.query

  m.id = SearchLight.DbId()

  m
end


function Base.count(m::Type{T}, q::SearchLight.SQLQuery = SearchLight.SQLQuery())::Int where {T<:SearchLight.AbstractModel}
  count_column = SearchLight.SQLColumn("COUNT(*) AS __cid", raw = true)
  q = SearchLight.clone(q, :columns, push!(q.columns, count_column))

  SearchLight.finddf(m, q)[1, Symbol("__cid")]
end



function SearchLight.update_query_part(m::T)::String where {T<:SearchLight.AbstractModel}
  update_values = join(map(x -> "$(string(SearchLight.SQLColumn(x))) = $(string(SearchLight.to_sqlinput(m, Symbol(x), getfield(m, Symbol(x)))) )", SearchLight.persistable_fields(typeof(m))), ", ")

  " $update_values WHERE $(SearchLight.table(typeof(m))).$(SearchLight.primary_key_name(typeof(m))) = '$(m.id.value)'"
end


function SearchLight.column_data_to_column_name(column::SearchLight.SQLColumn, column_data::Dict{Symbol,Any}) :: String
  "$(SearchLight.to_fully_qualified(column_data[:column_name], column_data[:table_name])) AS $(isempty(column_data[:alias]) ? SearchLight.to_sql_column_name(column_data[:column_name], column_data[:table_name]) : column_data[:alias] )"
end


function SearchLight.to_from_part(m::Type{T})::String where {T<:SearchLight.AbstractModel}
  "FROM " * SearchLight.escape_column_name(SearchLight.table(m), SearchLight.connection())
end


function SearchLight.to_where_part(w::Vector{SearchLight.SQLWhereEntity})::String
  where = isempty(w) ?
          "" :
          string("WHERE ",
                (string(first(w).condition) == "AND" ? "TRUE " : "FALSE "),
                join(map(wx -> string(wx), w), " "))

  replace(where, r"WHERE TRUE AND "i => "WHERE ")
end


function SearchLight.to_order_part(m::Type{T}, o::Vector{SearchLight.SQLOrder})::String where {T<:SearchLight.AbstractModel}
  isempty(o) ?
    "" :
    string("ORDER BY ",
            join(map(x -> string((! SearchLight.is_fully_qualified(x.column.value) ?
                                    SearchLight.to_fully_qualified(m, x.column) :
                                    x.column.value), " ", x.direction),
                      o), ", "))
end


function SearchLight.to_group_part(g::Vector{SearchLight.SQLColumn}) :: String
  isempty(g) ?
    "" :
    string(" GROUP BY ", join(map(x -> string(x), g), ", "))
end


function SearchLight.to_limit_part(l::SearchLight.SQLLimit) :: String
  l.value != "ALL" ? string("LIMIT ", string(l)) : ""
end


function SearchLight.to_offset_part(o::Int) :: String
  o != 0 ? string("OFFSET ", string(o)) : ""
end


function SearchLight.to_having_part(h::Vector{SearchLight.SQLWhereEntity}) :: String
  having =  isempty(h) ?
            "" :
            string("HAVING ",
                  (string(first(h).condition) == "AND" ? "TRUE " : "FALSE "),
                  join(map(w -> string(w), h), " "))

  replace(having, r"HAVING TRUE AND "i => "HAVING ")
end


function SearchLight.to_join_part(m::Type{T}, joins::Union{Nothing,Vector{SearchLight.SQLJoin{N}}} = nothing)::String where {T<:SearchLight.AbstractModel, N<:Union{Nothing,SearchLight.AbstractModel}}
  joins === nothing && return ""

  join(map(x -> string(x), joins), " ")
end


function Base.rand(m::Type{T}; limit = 1)::Vector{T} where {T<:SearchLight.AbstractModel}
  SearchLight.find(m, SearchLight.SQLQuery(limit = SearchLight.SQLLimit(limit), order = [SearchLight.SQLOrder("random()", raw = true)]))
end


#### MIGRATIONS ####


"""
    create_migrations_table(table_name::String)::Nothing

Runs a SQL DB query that creates the table `table_name` with the structure needed to be used as the DB migrations table.
The table should contain one column, `version`, unique, as a string of maximum 30 chars long.
"""
function SearchLight.Migration.create_migrations_table(table_name::String = SearchLight.config.db_migrations_table_name) :: Nothing
  
  queryString = string("select table_name from information_schema.tables where table_name = '$table_name'")
  if isempty(SearchLight.query(queryString))
    SearchLight.query("CREATE TABLE $table_name (version varchar(30))", internal = true)
    @info "Created table $table_name"
  else
    @info "Migration table exists."
  end

  nothing
end

"""
    drop_migrations_table(table_name::String)::Nothing

Runs a SQL DB query that drops the table `table_name`.
"""
function SearchLight.Migration.drop_migrations_table(table_name::String = SearchLight.config.db_migrations_table_name) :: Nothing
  
  
  queryString = string("select table_name from information_schema.tables where table_name = '$table_name'")
  if !isempty(SearchLight.query(queryString)) 

      SearchLight.query("DROP TABLE $table_name")
      @info "Droped table $table_name"
  else
      @info "Nothing to drop"
  end

  nothing
end


function SearchLight.Migration.create_table(f::Function, name::Union{String,Symbol}, options::Union{String,Symbol} = "") :: Nothing
  SearchLight.query(create_table_sql(f, string(name), options), internal = true)

  nothing
end


function create_table_sql(f::Function, name::String, options::String = "") :: String
  "CREATE TABLE $name (" * join(f()::Vector{String}, ", ") * ") $options" |> strip
end


function SearchLight.Migration.column(name::Union{String,Symbol}, column_type::Union{String,Symbol}, options::Any = ""; default::Any = nothing, limit::Union{Int,Nothing,String} = nothing, not_null::Bool = false) :: String
  "$name $(TYPE_MAPPINGS[column_type] |> string) " *
    (isa(limit, Int) ? "($limit)" : "") *
    (default === nothing ? "" : " DEFAULT $default ") *
    (not_null ? " NOT NULL " : "") *
    string(options)
end


function SearchLight.Migration.column_id(name::Union{String,Symbol} = "id", options::Union{String,Symbol} = ""; constraint::Union{String,Symbol} = "", nextval::Union{String,Symbol} = "") :: String
  "$name SERIAL $constraint PRIMARY KEY $nextval $options"
end


function SearchLight.Migration.add_index(table_name::Union{String,Symbol}, column_name::Union{String,Symbol}; name::Union{String,Symbol} = "", unique::Bool = false, order::Union{String,Symbol} = :none) :: Nothing
  name = isempty(name) ? SearchLight.index_name(table_name, column_name) : name
  SearchLight.query("CREATE $(unique ? "UNIQUE" : "") INDEX $(name) ON $table_name ($column_name)", internal = true)

  nothing
end


function SearchLight.Migration.add_column(table_name::Union{String,Symbol}, name::Union{String,Symbol}, column_type::Union{String,Symbol}; default::Union{String,Symbol,Nothing} = nothing, limit::Union{Int,Nothing} = nothing, not_null::Bool = false) :: Nothing
  SearchLight.query("ALTER TABLE $table_name ADD $(SearchLight.Migration.column(name, column_type, default = default, limit = limit, not_null = not_null))", internal = true)

  nothing
end


function SearchLight.Migration.drop_table(name::Union{String,Symbol}) :: Nothing
  SearchLight.query("DROP TABLE $name", internal = true)

  nothing
end


function SearchLight.Migration.remove_column(table_name::Union{String,Symbol}, name::Union{String,Symbol}, options::Union{String,Symbol} = "") :: Nothing
  SearchLight.query("ALTER TABLE $table_name DROP COLUMN $name $options", internal = true)

  nothing
end


function SearchLight.Migration.remove_index(name::Union{String,Symbol}, options::Union{String,Symbol} = "") :: Nothing
  SearchLight.query("DROP INDEX $name $options", internal = true)

  nothing
end


function SearchLight.Migration.create_sequence(name::Union{String,Symbol}) :: Nothing
  SearchLight.query("CREATE SEQUENCE $name", internal = true)

  nothing
end

function SearchLight.Migration.create_sequence(table_name::Union{String,Symbol}, column_name::Union{String,Symbol}) :: Nothing
  SearchLight.Migration.create_sequence(sequence_name(table_name, column_name))
end


function sequence_name(table_name::Union{String,Symbol}, column_name::Union{String,Symbol}) :: String
  string(table_name) * "__" * "seq_" * string(column_name)
end


function SearchLight.Migration.remove_sequence(name::Union{String,Symbol}, options::Union{String,Symbol}) :: Nothing
  SearchLight.query("DROP SEQUENCE $name $options", internal = true)

  nothing
end

function SearchLight.Migration.remove_sequence(table_column_name::Tuple{Union{String,Symbol},Union{String,Symbol}}, options::String = "") :: Nothing
  SearchLight.Migration.remove_sequence(sequence_name(string(table_column_name[1]), string(table_column_name[2])), options)
end


function SearchLight.Migration.constraint(table_name::Union{String,Symbol}, column_name::Union{String,Symbol}) :: String
  string("CONSTRAINT ", SearchLight.index_name(table_name, column_name))
end


function SearchLight.Migration.nextval(table_name::Union{String,Symbol}, column_name::Union{String,Symbol}) :: String
  "NEXTVAL('$(sequence_name(table_name, column_name) )')"
end


function SearchLight.Migration.column_id_sequence(table_name::Union{String,Symbol}, column_name::Union{String,Symbol})
  SearchLight.query("ALTER SEQUENCE $(sequence_name(table_name, column_name)) OWNED BY $table_name.$column_name")
end


#### GENERATOR ####


function SearchLight.Generator.FileTemplates.adapter_default_config()
  """
  $(SearchLight.config.app_env):
    adapter:  PostgreSQL
    host:     127.0.0.1
    port:     5432
    database: yourdb
    username: root
    password: ""
  """
end

end

