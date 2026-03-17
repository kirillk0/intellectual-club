defmodule IntellectualClub.DataLayer do
  @moduledoc """
  Delegating Ash data layer that supports both SQLite and PostgreSQL at runtime.

  Resources should define both `sqlite` and `postgres` sections.
  The active backend is selected in `config/runtime.exs`.
  """

  @behaviour Ash.DataLayer

  use Spark.Dsl.Extension,
    sections: AshSqlite.DataLayer.sections() ++ AshPostgres.DataLayer.sections(),
    transformers:
      (AshSqlite.DataLayer.transformers() ++ AshPostgres.DataLayer.transformers())
      |> Enum.uniq()

  defp impl, do: IntellectualClub.Db.data_layer()

  defp maybe_apply(fun, args, fallback) when is_list(args) do
    impl = impl()

    if function_exported?(impl, fun, length(args)) do
      apply(impl, fun, args)
    else
      resolve_fallback(fallback)
    end
  end

  defp resolve_fallback(fallback) when is_function(fallback, 0), do: fallback.()
  defp resolve_fallback(fallback), do: fallback

  @impl Ash.DataLayer
  def can?(resource, feature), do: impl().can?(resource, feature)

  @impl Ash.DataLayer
  def resource_to_query(resource, domain), do: impl().resource_to_query(resource, domain)

  @impl Ash.DataLayer
  def functions(resource), do: maybe_apply(:functions, [resource], [])

  @impl Ash.DataLayer
  def combination_of(combine, resource, domain),
    do:
      maybe_apply(
        :combination_of,
        [combine, resource, domain],
        {:error, "Query combination is not supported"}
      )

  @impl Ash.DataLayer
  def filter(query, filter, resource),
    do: maybe_apply(:filter, [query, filter, resource], {:error, "Filtering is not supported"})

  @impl Ash.DataLayer
  def combination_acc(query), do: maybe_apply(:combination_acc, [query], impl())

  @impl Ash.DataLayer
  def sort(query, sort, resource), do: impl().sort(query, sort, resource)

  @impl Ash.DataLayer
  def distinct_sort(query, sort, resource), do: impl().distinct_sort(query, sort, resource)

  @impl Ash.DataLayer
  def distinct(query, fields, resource), do: impl().distinct(query, fields, resource)

  @impl Ash.DataLayer
  def prefer_lateral_join_for_many_to_many?(),
    do: maybe_apply(:prefer_lateral_join_for_many_to_many?, [], true)

  @impl Ash.DataLayer
  def limit(query, limit, resource), do: impl().limit(query, limit, resource)

  @impl Ash.DataLayer
  def offset(query, offset, resource), do: impl().offset(query, offset, resource)

  @impl Ash.DataLayer
  def select(query, select, resource), do: impl().select(query, select, resource)

  @impl Ash.DataLayer
  def set_tenant(resource, query, tenant),
    do: maybe_apply(:set_tenant, [resource, query, tenant], {:ok, query})

  @impl Ash.DataLayer
  def transform_query(query), do: maybe_apply(:transform_query, [query], query)

  @impl Ash.DataLayer
  def run_query(query, resource), do: impl().run_query(query, resource)

  @impl Ash.DataLayer
  def lock(query, lock_type, resource),
    do: maybe_apply(:lock, [query, lock_type, resource], {:ok, query})

  @impl Ash.DataLayer
  def run_aggregate_query(query, aggregates, resource),
    do: impl().run_aggregate_query(query, aggregates, resource)

  @impl Ash.DataLayer
  def run_aggregate_query_with_lateral_join(
        query,
        aggregates,
        records,
        destination_resource,
        lateral_join_links
      ),
      do:
        impl().run_aggregate_query_with_lateral_join(
          query,
          aggregates,
          records,
          destination_resource,
          lateral_join_links
        )

  @impl Ash.DataLayer
  def run_query_with_lateral_join(query, records, source_resource, lateral_join_links),
    do: impl().run_query_with_lateral_join(query, records, source_resource, lateral_join_links)

  @impl Ash.DataLayer
  def return_query(query, resource),
    do: maybe_apply(:return_query, [query, resource], {:ok, query})

  @impl Ash.DataLayer
  def bulk_create(resource, changesets, opts), do: impl().bulk_create(resource, changesets, opts)

  @impl Ash.DataLayer
  def create(resource, changeset), do: impl().create(resource, changeset)

  @impl Ash.DataLayer
  def upsert(resource, changeset, keys), do: impl().upsert(resource, changeset, keys)

  @impl Ash.DataLayer
  def upsert(resource, changeset, keys, identity),
    do:
      maybe_apply(:upsert, [resource, changeset, keys, identity], fn ->
        impl().upsert(resource, changeset, keys)
      end)

  @impl Ash.DataLayer
  def update(resource, changeset), do: impl().update(resource, changeset)

  @impl Ash.DataLayer
  def update_query(query, changeset, resource, opts),
    do: impl().update_query(query, changeset, resource, opts)

  @impl Ash.DataLayer
  def destroy_query(query, changeset, resource, opts),
    do: impl().destroy_query(query, changeset, resource, opts)

  @impl Ash.DataLayer
  def add_aggregate(query, aggregate, resource),
    do: impl().add_aggregate(query, aggregate, resource)

  @impl Ash.DataLayer
  def add_aggregates(query, aggregates, resource),
    do: impl().add_aggregates(query, aggregates, resource)

  @impl Ash.DataLayer
  def add_calculation(query, calculation, expression, resource),
    do: impl().add_calculation(query, calculation, expression, resource)

  @impl Ash.DataLayer
  def add_calculations(query, calculations, resource),
    do: impl().add_calculations(query, calculations, resource)

  @impl Ash.DataLayer
  def destroy(resource, changeset), do: impl().destroy(resource, changeset)

  @impl Ash.DataLayer
  def transaction(resource, func, timeout, reason),
    do: maybe_apply(:transaction, [resource, func, timeout, reason], fn -> {:ok, func.()} end)

  @impl Ash.DataLayer
  def in_transaction?(resource), do: maybe_apply(:in_transaction?, [resource], false)

  @impl Ash.DataLayer
  def source(resource), do: impl().source(resource)

  @impl Ash.DataLayer
  def rollback(resource, term),
    do: maybe_apply(:rollback, [resource, term], fn -> raise(term) end)

  @impl Ash.DataLayer
  def calculate(resource, exprs, context),
    do:
      maybe_apply(
        :calculate,
        [resource, exprs, context],
        {:error, "Calculations are not supported"}
      )

  @impl Ash.DataLayer
  def prefer_transaction?(resource), do: maybe_apply(:prefer_transaction?, [resource], true)

  @impl Ash.DataLayer
  def prefer_transaction_for_atomic_updates?(resource),
    do: maybe_apply(:prefer_transaction_for_atomic_updates?, [resource], true)

  @impl Ash.DataLayer
  def set_context(resource, query, context), do: impl().set_context(resource, query, context)
end
