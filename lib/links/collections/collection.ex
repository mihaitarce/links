defmodule Links.Collections.Collection do
  use Ecto.Schema
  import Ecto.Changeset

  alias Links.Accounts.User
  alias Links.Bookmarks.Bookmark

  schema "collections" do
    field :title, :string
    field :position, :integer, default: 0
    field :collaboration_readonly, :boolean, default: false
    field :collaboration_revoked_at, :utc_datetime

    belongs_to :owner, User
    belongs_to :parent, __MODULE__
    belongs_to :collaboration, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :bookmarks, Bookmark

    timestamps(type: :utc_datetime)
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [
      :title,
      :position,
      :owner_id,
      :parent_id,
      :collaboration_id,
      :collaboration_readonly,
      :collaboration_revoked_at
    ])
    |> validate_required([:title, :owner_id])
    |> validate_length(:title, min: 1, max: 160)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:owner_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:collaboration_id)
    |> unique_constraint([:owner_id, :collaboration_id],
      name: :collections_active_collaboration_owner_source_index
    )
  end
end
