# frozen_string_literal: true

RSpec.shared_context "with nvim", :nvim do
  let(:nvim_mode) { :pipe }
  let(:nvim) { NeovimClient.new(nvim_mode) }

  # CI drives the suite once per backend (migration spec §6): NEOGIT_GIT_BACKEND
  # is set to "cli" for the control run and "auto"/"libgit2" for the libgit2 run.
  let(:neogit_config) do
    backend = ENV["NEOGIT_GIT_BACKEND"]
    backend ? "{ git_backend = '#{backend}' }" : "{}"
  end

  before { nvim.setup(neogit_config) }
  after { nvim.teardown }
end
