cd(@__DIR__)
Pkg.activate(".")

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

        #insert tables you use in tests here
        tables = ["Book","BookWithIntern","Callback"]

        #obtain tables exists or not, if they does drop it
        wheres = join(map(x->string("'",lowercase(SearchLight.Inflector.to_plural(x)),"'"),tables)," , ", " , ")
        queryString = string("select table_name from information_schema.tables where table_name in ($wheres)")
        result = SearchLight.query(queryString)
        for item in eachrow(result)
          try
            SearchLight.Migration.drop_table(lowercase(item[1]))
          catch ex
            @show "Table $item doesn't exist"
          end 
        end 
  
        SearchLight.disconnect(conn)
        rm(SearchLight.config.db_migrations_folder,force=true, recursive=true)
    end
  end

end

@safetestset "Models and tableMigration" begin
  using SearchLight
  using SearchLightPostgreSQL
  using LibPQ
  using Main.TestSetupTeardown

  ## against the convention bind the TestModels from testmodels.jl in the testfolder
  include(joinpath(@__DIR__,"test_Models.jl"))
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