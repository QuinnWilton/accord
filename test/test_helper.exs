ExUnit.start()

unless Accord.Test.TLACheck.tlc_available?() do
  ExUnit.configure(exclude: [:tlc])
end
