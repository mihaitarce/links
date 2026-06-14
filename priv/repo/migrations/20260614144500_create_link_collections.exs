defmodule Links.Repo.Migrations.CreateLinkCollections do
  use Ecto.Migration

  def change do
    create table(:collections) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :parent_id, references(:collections, on_delete: :delete_all)
      add :collaboration_id, references(:collections, on_delete: :delete_all)
      add :collaboration_readonly, :boolean, null: false, default: false
      add :collaboration_revoked_at, :utc_datetime
      add :title, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:collections, [:owner_id])
    create index(:collections, [:parent_id])
    create index(:collections, [:collaboration_id])

    create unique_index(:collections, [:owner_id, :collaboration_id],
             where: "collaboration_id IS NOT NULL AND collaboration_revoked_at IS NULL",
             name: :collections_active_collaboration_owner_source_index
           )

    create table(:bookmarks) do
      add :collection_id, references(:collections, on_delete: :delete_all)
      add :created_by_id, references(:users), null: false
      add :title, :string, null: false
      add :url, :text, null: false
      add :description, :text
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:bookmarks, [:collection_id])
    create index(:bookmarks, [:created_by_id])

    create table(:collection_public_shares) do
      add :collection_id, references(:collections, on_delete: :delete_all), null: false
      add :created_by_id, references(:users), null: false
      add :token, :string, null: false
      add :revoked_at, :utc_datetime
      add :last_accessed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:collection_public_shares, [:collection_id])
    create unique_index(:collection_public_shares, [:token])

    create unique_index(:collection_public_shares, [:collection_id],
             where: "revoked_at IS NULL",
             name: :collection_public_shares_one_active_share_index
           )
  end
end
