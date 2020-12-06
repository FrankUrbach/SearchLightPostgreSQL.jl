using Pkg

cd(@__DIR__)

using Test, TestSetExtensions, SafeTestsets

@testset ExtendedTestSet "SearchLight PostgreSQL adapter tests" begin
  @includetests ARGS
end