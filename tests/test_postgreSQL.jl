using Pkg

using Test, TestSetExtensions, SafeTestsets
using SearchLight
using SearchLightPostgreSQL

module TestSetupTeardown

  using SearchLight
  using SearchLightPostgreSQL

  export prepareDbConnection, tearDown

  connection_file = "postgres_connection.yml"

  function prepareDbConnection()
      
      conn_info_postgres = SearchLight.Configuration.load(connection_file)
      conn = SearchLight.connect(conn_info_postgres)
      return conn
  end

  function tearDown(conn)
    if conn !== nothing
        ######## Dropping used tables
        SearchLight.Migration.drop_migrations_table()
        try
          SearchLight.Migration.drop_table(lowercase("Books"))
          SearchLight.Migration.drop_table(lowercase("BookWithInterns"))
        catch ex
          @show "One of the tables to drop doesn't exit"
        end 
  
        SearchLight.disconnect(conn)
        rm(SearchLight.config.db_migrations_folder,force=true, recursive=true)
    end
  end

end

@safetestset "Core features PostgreSQL" begin
  using SearchLight
  using SearchLightPostgreSQL
  using Test, TestSetExtensions
  using Main.TestSetupTeardown


  @testset "PostgresSQL configuration" begin

    conn_info_postgres = SearchLight.Configuration.load(TestSetupTeardown.connection_file)

    @test conn_info_postgres["adapter"] == "PostgreSQL"
    @test conn_info_postgres["host"] == "127.0.0.1"
    @test conn_info_postgres["password"] == "postgres"
    @test conn_info_postgres["config"]["log_level"] == ":debug"
    @test conn_info_postgres["port"] == 5432
    @test conn_info_postgres["username"] == "postgres"
    @test conn_info_postgres["config"]["log_queries"] == true
    @test conn_info_postgres["database"] == "searchlight_tests"

  end
end;

@safetestset "PostgresSQL connection" begin
  using SearchLight
  using SearchLightPostgreSQL
  using LibPQ
  using Main.TestSetupTeardown

  
  conn = prepareDbConnection()
  
  infoDB = LibPQ.conninfo(conn)

  keysInfo = Dict{String, String}()

  push!(keysInfo, "host"=>"127.0.0.1")
  push!(keysInfo, "port"=>"5432")
  push!(keysInfo, "dbname" => "searchlight_tests")
  push!(keysInfo, "user"=> "postgres")

  for info in keysInfo
    infokey = info[1]
    infoVal = info[2]
    indexInfo = Base.findfirst(x->x.keyword == infokey, infoDB)
    valInfo = infoDB[indexInfo].val
    @test infoVal == valInfo
  end

  tearDown(conn)

end


@safetestset "PostgresSQL query" begin
  using SearchLight
  using SearchLightPostgreSQL
  using SearchLight.Configuration
  using SearchLight.Migrations
  using Main.TestSetupTeardown

  conn = prepareDbConnection()

  queryString = string("select table_name from information_schema.tables where table_name = '",SearchLight.SEARCHLIGHT_MIGRATIONS_TABLE_NAME,"'")

  @test isempty(SearchLight.query(queryString,conn)) == true
  
  #create migrations_table
  SearchLight.Migration.create_migrations_table()

  @test Array(SearchLight.query(queryString,conn))[1] == SearchLight.SEARCHLIGHT_MIGRATIONS_TABLE_NAME

  tearDown(conn)

end;

@safetestset "Utility functions PostgreSQL-Adapter" begin
  using SearchLight
  using SearchLightPostgreSQL
  using SearchLight.Migration
  using SearchLight.Configuration
  using Main.TestSetupTeardown

  conn = prepareDbConnection()

  @test SearchLight.Migration.create_migrations_table() === nothing
  @test SearchLight.Migration.drop_migrations_table() === nothing


  tearDown(conn)

end

@safetestset "Models and tableMigration" begin
  using SearchLight
  using SearchLightPostgreSQL
  using LibPQ
  using Main.TestSetupTeardown

  ## against the convention bind the TestModels from testmodels.jl in the testfolder
  include("test_Models.jl")
  using Main.TestModels

  ## establish the database-connection
  conn = prepareDbConnection()

  ## create migrations_table
  SearchLight.Migration.create_migrations_table()
  
  ## make Table "Book" 
  SearchLight.Generator.new_table_migration(Book)
  SearchLight.Migration.up()

  testBook = Book(title="Faust",author="Goethe")

  @test testBook.author == "Goethe"
  @test testBook.title == "Faust"
  @test typeof(testBook) == Book
  @test isa(testBook, AbstractModel)

  testBook |> SearchLight.save

  @test testBook |> SearchLight.save == true

  ############ tearDown ##################

  tearDown(conn)

end

@safetestset "Model Store and Query models without inern variables" begin
  using SearchLight
  using SearchLightPostgreSQL
  ## against the convention bind the TestModels from testmodels.jl in the testfolder
  include("test_Models.jl")
  using .TestModels
  using Main.TestSetupTeardown

  ## establish the database-connection
  conn = prepareDbConnection()

  ## create migrations_table
  SearchLight.Migration.create_migrations_table()
  
  ## make Table "Book" 
  SearchLight.Generator.new_table_migration(Book)
  SearchLight.Migration.up()

  testBooks = Book[]
  
  ## prepare the TestBooks
  for book in TestModels.seed() 
    push!(testBooks,Book(title=book[1], author=book[2]))
  end

  @test testBooks |> SearchLight.save == true

  booksReturn = SearchLight.find(Book)

  @test size(booksReturn) == (5,)

 
  ############ tearDown ##################

  tearDown(conn)

end

@safetestset "Query and Models with intern variables" begin
  using Test
  using SearchLight
  using SearchLightPostgreSQL
  using Main.TestSetupTeardown

    ## against the convention bind the TestModels from testmodels.jl in the testfolder
    include("test_Models.jl")
    using Main.TestModels

    ## establish the database-connection
    conn = prepareDbConnection()

    ## make Table "BooksWithInterns" 
    SearchLight.Generator.new_table_migration(BookWithInterns)
    SearchLight.Migration.up()

    booksWithInterns = BookWithInterns[]

    ## prepare the TestBooks
    for book in TestModels.seed() 
      push!(booksWithInterns,BookWithInterns(title=book[1], author=book[2]))
    end

    testItem = BookWithInterns(author="Alexej Tolstoi", title="Krieg oder Frieden")

    savedTestItem = SearchLight.save(testItem)
    @test savedTestItem === true

    savedTestItems = booksWithInterns |> save
    @test savedTestItems === true

    idTestItem = SearchLight.save!(testItem)
    @test idTestItem.id !== nothing
    @test idTestItem.id.value  > 0

    resultBooksWithInterns = booksWithInterns |> save!

    fullTestBooks = find(BookWithInterns)
    @test isa(fullTestBooks,Array{BookWithInterns,1})
    @test length(fullTestBooks) > 0
 
    ############ tearDown ##################
    tearDown(conn)

end## end of testset

@safetestset "Saving and Reading with callbacks" begin
    using SearchLight
    using SearchLightPostgreSQL
    using Main.TestSetupTeardown
    using Dates

    include("test_models.jl")
    using Main.TestModels

    prepareDbConnection()

    testItem = Callback(title = "testing")
    SearchLight.Generator.new_table_migration("Callback")
    SearchLight.Migration.up()

    testItem|>save!

end;

