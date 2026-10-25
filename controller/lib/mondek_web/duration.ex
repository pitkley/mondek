# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Duration do
  @moduledoc "Readable schedule durations without rounding away fractional seconds."

  @spec format_seconds(number() | nil) :: String.t()
  def format_seconds(value) when is_number(value) and value >= 0 do
    {whole, fraction} = decimal_parts(value)

    {parts, seconds} =
      Enum.reduce([{86_400, "day"}, {3_600, "hour"}, {60, "minute"}], {[], whole}, fn
        {unit_seconds, unit}, {parts, remaining} ->
          amount = div(remaining, unit_seconds)
          parts = if amount > 0, do: parts ++ [unit(amount, unit)], else: parts
          {parts, rem(remaining, unit_seconds)}
      end)

    seconds = Integer.to_string(seconds) <> if(fraction == "", do: "", else: "." <> fraction)

    parts =
      if seconds != "0" || parts == [],
        do: parts ++ [unit(seconds, "second")],
        else: parts

    Enum.join(parts, " ")
  end

  def format_seconds(_), do: "Not recorded"

  defp unit(amount, name) when amount in [1, "1"], do: "1 " <> name
  defp unit(amount, name), do: to_string(amount) <> " " <> name <> "s"

  defp decimal_parts(value) when is_integer(value), do: {value, ""}

  defp decimal_parts(value) do
    # The shortest decimal representation retains the stored float's precision.
    # Subtracting whole minutes from a float can invent digits such as 0.099999…;
    # split its decimal coefficient instead, also expanding scientific notation.
    [significand | exponent] = String.split(Float.to_string(value), "e")
    exponent = if exponent == [], do: 0, else: String.to_integer(hd(exponent))
    [whole, fraction] = String.split(significand, ".")
    places = String.length(fraction) - exponent
    coefficient = String.to_integer(whole <> fraction)

    if places <= 0 do
      {coefficient * Integer.pow(10, -places), ""}
    else
      factor = Integer.pow(10, places)

      fraction =
        coefficient
        |> rem(factor)
        |> Integer.to_string()
        |> String.pad_leading(places, "0")
        |> String.trim_trailing("0")

      {div(coefficient, factor), fraction}
    end
  end
end
