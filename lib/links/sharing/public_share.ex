defmodule Links.Sharing.PublicShare do
  use Ecto.Schema
  import Ecto.Changeset

  alias Links.Accounts.User
  alias Links.Collections.Collection

  schema "collection_public_shares" do
    field :token, :string
    field :revoked_at, :utc_datetime
    field :last_accessed_at, :utc_datetime

    belongs_to :collection, Collection
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  def changeset(public_share, attrs) do
    public_share
    |> cast(attrs, [:collection_id, :created_by_id, :token, :revoked_at, :last_accessed_at])
    |> validate_required([:collection_id, :created_by_id, :token])
    |> validate_length(:token, min: 24, max: 128)
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:created_by_id)
    |> unique_constraint(:token)
  end
end
