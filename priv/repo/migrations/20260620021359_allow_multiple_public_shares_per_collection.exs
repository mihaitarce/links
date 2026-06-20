defmodule Links.Repo.Migrations.AllowMultiplePublicSharesPerCollection do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:collection_public_shares, [:collection_id],
                     name: :collection_public_shares_one_active_share_index
                   )
  end
end
