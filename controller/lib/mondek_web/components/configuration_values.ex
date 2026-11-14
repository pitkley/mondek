# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationValues do
  use Phoenix.Component
  alias Mondek.Parameters

  attr :assignment, :map, required: true
  attr :values, :map, default: %{}

  def comparison(assigns) do
    current = assigns.assignment["params"] || %{}
    source = assigns.assignment["source_defaults"] || %{}
    origin = assigns.assignment["configuration_origin"] || %{}
    exception? = origin["kind"] == "exception"
    fallback = assigns.values["masked_params"]

    keys =
      current
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(fn key ->
        not Parameters.same_json?(current[key], source[key]) or
          (exception? and is_map(fallback) and
             not Parameters.same_json?(current[key], fallback[key]))
      end)

    assigns =
      assign(assigns,
        current: current,
        source: source,
        origin: origin,
        exception?: exception?,
        fallback: fallback,
        keys: keys
      )

    ~H"""
    <section
      :if={@origin["kind"] in ["rule", "exception"]}
      id="configuration-value-comparison"
      class="configuration-value-comparison"
      aria-labelledby="configuration-value-heading"
    >
      <h3 id="configuration-value-heading">Defaults from code are overridden</h3>
      <p class="configuration-values-note">
        This {if @exception?, do: "instance exception", else: "rule"} supplies the complete parameter set. Changing defaults in Python will not replace these saved values.
      </p>
      <MondekWeb.PreviewDetail.facts
        :if={
          @origin["managed_project"] || (@exception? && @values["masked_origin"]) ||
            (@exception? && @values["masked_error"])
        }
        label="Saved policy scope"
      >
        <tr :if={@origin["managed_project"]}>
          <th scope="row">Project</th><td class="managed-policy-label">
            {@origin["managed_project"]}<span :if={@origin["managed_key"]}> · {@origin["managed_key"]}</span>
          </td>
        </tr>
        <tr :if={@exception? && @values["masked_origin"]} id="configuration-under-exception">
          <th scope="row">Without this exception</th><td>
            <.origin value={@values["masked_origin"]} />. Review removal to start following those values.
          </td>
        </tr>
        <tr :if={@exception? && @values["masked_error"]} id="configuration-hidden-conflict">
          <th scope="row">Removal blocked</th><td>{@values["masked_error"]}</td>
        </tr>
      </MondekWeb.PreviewDetail.facts>
      <p :if={@keys == []} class="configuration-values-note">
        The saved values currently equal the defaults from code. The override still takes precedence over future default changes.
      </p>
      <%= if @keys != [] do %>
        <p class="configuration-values-note">
          Saved settings are compared here. Each result retains the values used for its last measurement.
        </p>
        <table class="configuration-values-table" aria-label="Saved values compared with defaults">
          <thead>
            <tr>
              <th scope="col">Parameter</th><th scope="col">Default from code</th><th scope="col">
                Saved value
              </th><th :if={@exception? && is_map(@fallback)} scope="col">Without exception</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={key <- @keys} class="configuration-difference">
              <th scope="row">
                {get_in(@assignment, ["parameter_schema", "fields", key, "label"]) || key}<span :if={
                  get_in(@assignment, ["parameter_schema", "fields", key, "unit"])
                }> ({get_in(@assignment, ["parameter_schema", "fields", key, "unit"])})</span>
              </th>
              <td>{value(@source[key])}</td><td>{value(@current[key])}</td><td :if={
                @exception? && is_map(@fallback)
              }>
                {value(@fallback[key])}
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  attr :value, :map, required: true

  def origin(assigns) do
    ~H"""
    <span>
      <%= if @value["kind"] == "rule" do %>
        rule
        <a href={"/configuration/rules/" <> @value["rule_id"]}>{@value["rule_name"] ||
          @value["rule_id"]}</a>
        <span :if={@value["managed_project"]}>(project {@value["managed_project"]})</span>
      <% else %>
        {if @value["kind"] == "exception", do: "instance exception", else: "defaults from code"}
      <% end %>
    </span>
    """
  end

  def workflow(assigns) do
    ~H"""
    <details id="configuration-as-code" class="configuration-as-code">
      <summary>Versioned settings through UI and Git</summary>
      <div class="notice-copy">
        <p>
          Keep check parameters in Python when defaults from code are sufficient. Rules are optional:
          use them to share policy across present and future checks or change it independently of check deployment.
        </p>
        <p>
          <code>mondek-policy inspect --source SOURCE --controller URL</code> shows saved values,
          defaults from code and overrides. It does not run checks or change settings.
        </p>
        <p>
          UI saves automatically record configuration history. You can also clone the controller's configuration repository,
          edit its data files and push to main after review. Projects organize rules; they do not lock out UI editing. <a href="/configuration/history">Inspect history and Git instructions</a>.
        </p>
        <p>
          Instance exceptions remain explicit and can mask project policy. Saving policy does not mean a runner has measured it yet.
        </p>
      </div>
    </details>
    """
  end

  defp value(value) when is_binary(value), do: value
  defp value(value), do: Jason.encode!(value)
end
