defmodule Earmark.Ast.Renderer.TableRenderer do
  @moduledoc false

  alias Earmark.Ast.Inline

  def render_header(header, lnb, aligns, context) do
    {th_ast, context1} = 
      header
      |> Enum.zip(aligns)
      |> Enum.map_reduce(context, &_render_col(&1, &2, lnb, :th))
    {{ "thead", [], [
      { "tr", [],
          th_ast}]}, context1}
  end

  def render_rows(rows, lnb, aligns, context) do
    {rows1, context1} =
      rows
        |> Enum.zip(Stream.iterate(lnb, &(&1 + 1)))
        |> Enum.map_reduce(context, &_render_row(&1, &2, aligns))
    {[{"tbody", [], rows1}], context1} 
  end


  defp _render_cols(row, lnb, aligns, context, coltype \\ :td) do
    row
    |> Enum.zip(aligns)
    |> Enum.map_reduce(context, &_render_col(&1, &2, lnb, coltype))
  end

  defp _render_col({col, align}, context, lnb, coltype) do
    context1 = Inline.convert(col, lnb, context|>Earmark.Context.set_value([])) 
    {{"#{coltype}", _align_to_style(align), context1.value}, context1}
  end

  defp _render_row({row, lnb}, context, aligns) do
    {ast, context1} = _render_cols(row, lnb, aligns, context)
    {{"tr", [], ast}, context1}
  end

  defp _align_to_style(align)
  defp _align_to_style(:left), do: [{"style", "text-align: left;"}]
  defp _align_to_style(:right), do: [{"style", "text-align: right;"}]
  defp _align_to_style(:center), do: [{"style", "text-align: center;"}]
  defp _align_to_style(_), do: []
end
