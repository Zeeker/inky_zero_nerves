defmodule Inky do
  @moduledoc """
  Documentation for Inky.
  """

  @doc """
  Hello world.

  ## Examples

      iex> alias Inky
      iex> state = Inky.setup(nil, :phat, :red)
      iex> state = Enum.reduce(0..(state.height - 1), state, fn y, state ->Enum.reduce(0..(state.width - 1), state, fn x, state ->Inky.set_pixel(state, x, y, state.red)end)end)
      iex> Inky.show(state)

  """

  alias Circuits.SPI
  alias Circuits.GPIO
  alias Inky.InkyPhat
  alias Inky.InkyWhat
  alias Inky.State
  # alias Inky.Pixel

  @reset_pin 27
  @busy_pin 17
  @dc_pin 22

  # @mosi_pin 10
  # @sclk_pin 11
  @cs0_pin 0

  @spi_chunk_size 4096
  @spi_command 0
  @spi_data 1

  # Used in logo example
  # inkyphat and inkywhat classes
  # color constants: RED, BLACK, WHITE
  # dimension constants: WIDTH, HEIGHT
  # PIL: putpixel(value)
  # set_image
  # show

  # SPI bus options include:
  # * `mode`: This specifies the clock polarity and phase to use. (0)
  # * `bits_per_word`: bits per word on the bus (8)
  # * `speed_hz`: bus speed (1000000)
  # * `delay_us`: delay between transaction (10)

  def setup(state \\ nil, type, luts_color)
      when type in [:phat, :what] and luts_color in [:black, :red, :yellow] do
    state =
      case state do
        %State{} ->
          state

        nil ->
          {:ok, dc_pid} = GPIO.open(@dc_pin, :output)
          {:ok, reset_pid} = GPIO.open(@reset_pin, :output)
          {:ok, busy_pid} = GPIO.open(@busy_pin, :input)
          # GPIO.write(gpio_pid, 1)
          {:ok, spi_pid} = SPI.open("spidev0." <> to_string(@cs0_pin), speed_hz: 488_000)
          # Use binary pattern matching to pull out the ADC counts (low 10 bits)
          # <<_::size(6), counts::size(10)>> = SPI.transfer(spi_pid, <<0x78, 0x00>>)
          %State{
            dc_pid: dc_pid,
            reset_pid: reset_pid,
            busy_pid: busy_pid,
            spi_pid: spi_pid,
            color: luts_color
          }
      end

    GPIO.write(state.reset_pid, 0)
    :timer.sleep(100)
    GPIO.write(state.reset_pid, 1)
    :timer.sleep(100)

    state =
      case type do
        :phat -> InkyPhat.update_state(state)
        :what -> InkyWhat.update_state(state)
      end

    soft_reset(state)
    busy_wait(state)
    state
  end

  def set_pixel(state = %State{}, x, y, value) do
    state =
      if value in [state.white, state.black, state.red, state.yellow] do
        put_in(state.pixels[{x, y}], value)
        # %{state | pixels: %{state.pixels | {x, y}: value} }
      else
        state
      end

    state
  end

  def show(state = %State{}) do
    # Not implemented: vertical flip
    # Not implemented: horizontal flip

    # Note: Rotation handled when converting to bytestring

    black_bytes = pixels_to_bytestring(state, state.black, 0, 1)
    red_bytes = pixels_to_bytestring(state, state.red, 1, 0)
    update(state, black_bytes, red_bytes)
  end

  def log_grid(state = %State{}) do
    grid =
      Enum.reduce(0..(state.height - 1), "", fn y, grid ->
        row =
          Enum.reduce(0..(state.width - 1), "", fn x, row ->
            color_value = Map.get(state.pixels, {x, y}, 0)

            row <>
              case color_value do
                0 -> "W"
                1 -> "B"
                2 -> "R"
              end
          end)

        grid <> row <> "\n"
      end)

    IO.puts(grid)
  end

  # Private functionality

  defp busy_wait(state) do
    busy = GPIO.read(state.busy_pid)

    case busy do
      0 ->
        state

      false ->
        state

      1 ->
        :timer.sleep(10)
        busy_wait(state)

      true ->
        :timer.sleep(10)
        busy_wait(state)
    end
  end

  defp update(state, buffer_a, buffer_b) do
    setup(state, state.type, state.color)

    ## Straight ported from python library, I know very little what I'm doing here

    # little endian, unsigned short
    packed_height = [
      :binary.encode_unsigned(Enum.fetch!(state.resolution_data, 1), :little),
      <<0x00>>
    ]

    # Skipped map ord thing for packed_height..
    # IO.puts("Starting to send shit..")

    # Set analog block control
    # IO.inspect("# Set analog block control")
    send_command(state, 0x74, 0x54)

    # Set digital block control
    # IO.inspect("# Set digital block control")
    send_command(state, 0x7E, 0x3B)

    # Gate setting
    # IO.inspect("# Gate setting")
    send_command(state, 0x01, :binary.list_to_bin(packed_height ++ [0x00]))

    # Gate driving voltage
    # IO.inspect("# Gate driving voltage")
    send_command(state, 0x03, [0b10000, 0b0001])

    # Dummy line period
    # IO.inspect("# Dummy line period")
    send_command(state, 0x3A, 0x07)

    # Gate line width
    # IO.inspect("# Gate line width")
    send_command(state, 0x3B, 0x04)

    # Data entry mode setting 0x03 = X/Y increment
    # IO.inspect("# Data entry mode setting 0x03 = X/Y increment")
    send_command(state, 0x11, 0x03)

    # Power on
    # IO.inspect("# Power on")
    send_command(state, 0x04)

    # VCOM Register, 0x3c = -1.5v?
    # IO.inspect("# VCOM Register, 0x3c = -1.5v?")
    send_command(state, 0x2C, 0x3C)
    send_command(state, 0x3C, 0x00)

    # Always black border
    # IO.inspect("# Always black border")
    send_command(state, 0x3C, 0x00)

    # Set voltage of VSH and VSL on Yellow device
    if state.color == :yellow do
      send_command(state, 0x04, 0x07)
    end

    # Set LUTs
    # IO.inspect("# Set LUTs")
    send_command(state, 0x32, get_luts(state.color))

    # Set RAM X Start/End
    # IO.inspect("# Set RAM X Start/End")
    send_command(state, 0x44, :binary.list_to_bin([0x00, trunc(state.columns / 8) - 1]))

    # Set RAM Y Start/End
    # IO.inspect("# Set RAM Y Start/End")
    send_command(state, 0x45, :binary.list_to_bin([0x00, 0x00] ++ packed_height))

    # 0x24 == RAM B/W, 0x26 == RAM Red/Yellow/etc
    for data <- [{0x24, buffer_a}, {0x26, buffer_b}] do
      {cmd, buffer} = data

      # Set RAM X Pointer start
      # IO.inspect("# Set RAM X Pointer start")
      send_command(state, 0x4E, 0x00)

      # Set RAM Y Pointer start
      # IO.inspect("# Set RAM Y Pointer start")
      send_command(state, 0x4F, <<0x00, 0x00>>)
      # IO.inspect("# Buffer thing")
      send_command(state, cmd, buffer)
    end

    # Display Update Sequence
    # IO.inspect("# Display Update Sequence")
    send_command(state, 0x22, 0xC7)

    # Trigger Display Update
    # IO.inspect("# Trigger Display Update")
    send_command(state, 0x20)

    # Wait Before Deep Sleep
    :timer.sleep(50)
    busy_wait(state)

    # Enter Deep Sleep
    # IO.inspect("# Enter deep sleep")
    send_command(state, 0x10, 0x01)
  end

  def pixels_to_bytestring(state = %State{}, color_value, match, no_match) do
    rotation = state.rotation / 90

    {order, outer_from, outer_to, inner_from, inner_to} =
      case rotation do
        -1.0 -> {:x_outer, state.width - 1, 0, 0, state.height - 1}
        1.0 -> {:x_outer, 0, state.width - 1, state.height - 1, 0}
        -2.0 -> {:y_outer, state.width - 1, 0, state.height - 1, 0}
        _ -> {:y_outer, 0, state.height - 1, 0, state.width - 1}
      end

    for i <-
          Enum.flat_map(outer_from..outer_to, fn i ->
            Enum.map(inner_from..inner_to, fn j ->
              key =
                case order do
                  :x_outer -> {i, j}
                  :y_outer -> {j, i}
                end

              case state.pixels[key] do
                ^color_value -> match
                _ -> no_match
              end
            end)
          end),
        do: <<i::1>>,
        into: <<>>
  end

  defp soft_reset(state = %State{}) do
    send_command(state, 0x12)
  end

  defp send_command(state = %State{}, command) when is_binary(command) do
    # IO.inspect("send_command/2 binary")
    spi_write(state, @spi_command, command)
  end

  defp send_command(state = %State{}, command) do
    # IO.inspect("send_command/2")
    spi_write(state, @spi_command, <<command>>)
  end

  defp send_command(state = %State{}, command, data) do
    # IO.inspect("send_command/3")
    send_command(state, <<command>>)
    send_data(state, data)
  end

  defp send_data(state = %State{}, data) when is_integer(data) do
    # IO.inspect("send_data/2 int")
    spi_write(state, @spi_data, <<data>>)
  end

  defp send_data(state = %State{}, data) do
    # IO.inspect("send_command/2")
    spi_write(state, @spi_data, data)
  end

  defp spi_write(state = %State{}, data_or_command, values) when is_list(values) do
    # IO.inspect("spi_write/3 list")
    # IO.puts("spi_write/3 GPIO...")
    GPIO.write(state.dc_pid, data_or_command)
    # IO.puts("[done]")
    # IO.puts("spi_write/3 SPI transfer")
    {:ok, <<_::binary>>} = SPI.transfer(state.spi_pid, :erlang.list_to_binary(values))
    # IO.puts("[done]")
    state
  end

  defp spi_write(state = %State{}, data_or_command, values) when is_binary(values) do
    # IO.inspect("spi_write/3 binary")
    # IO.puts("spi_write/3 GPIO...")
    GPIO.write(state.dc_pid, data_or_command)
    # IO.puts("[done]")
    # IO.puts("spi_write/3 SPI transfer")
    {:ok, <<_::binary>>} = SPI.transfer(state.spi_pid, values)
    # IO.puts("[done]")
    state
  end

  def try_get_state() do
    state = Inky.setup(nil, :phat, :red)

    Enum.reduce(0..(state.height - 1), state, fn y, state ->
      Enum.reduce(0..(state.width - 1), state, fn x, state ->
        Inky.set_pixel(state, x, y, state.red)
      end)
    end)
  end

  def try(state) do
    Inky.show(state)
  end

  defp get_luts(:black) do
    <<
      # Phase 0     Phase 1     Phase 2     Phase 3     Phase 4     Phase 5     Phase 6
      # A B C D     A B C D     A B C D     A B C D     A B C D     A B C D     A B C D
      # LUT0 - Black
      0b01001000,
      0b10100000,
      0b00010000,
      0b00010000,
      0b00010011,
      0b00000000,
      0b00000000,
      # LUTT1 - White
      0b01001000,
      0b10100000,
      0b10000000,
      0b00000000,
      0b00000011,
      0b00000000,
      0b00000000,
      # IGNORE
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      # LUT3 - Red
      0b01001000,
      0b10100101,
      0b00000000,
      0b10111011,
      0b00000000,
      0b00000000,
      0b00000000,
      # LUT4 - VCOM
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,

      # Duration            |  Repeat
      # A   B     C     D   |
      # 0 Flash
      16,
      4,
      4,
      4,
      4,
      # 1 clear
      16,
      4,
      4,
      4,
      4,
      # 2 bring in the black
      4,
      8,
      8,
      16,
      16,
      # 3 time for red
      0,
      0,
      0,
      0,
      0,
      # 4 final black sharpen phase
      0,
      0,
      0,
      0,
      0,
      # 5
      0,
      0,
      0,
      0,
      0,
      # 6
      0,
      0,
      0,
      0,
      0
    >>
  end

  defp get_luts(:red) do
    <<
      # Phase 0     Phase 1     Phase 2     Phase 3     Phase 4     Phase 5     Phase 6
      # A B C D     A B C D     A B C D     A B C D     A B C D     A B C D     A B C D
      # LUT0 - Black
      0b01001000,
      0b10100000,
      0b00010000,
      0b00010000,
      0b00010011,
      0b00000000,
      0b00000000,
      # LUTT1 - White
      0b01001000,
      0b10100000,
      0b10000000,
      0b00000000,
      0b00000011,
      0b00000000,
      0b00000000,
      # IGNORE
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      # LUT3 - Red
      0b01001000,
      0b10100101,
      0b00000000,
      0b10111011,
      0b00000000,
      0b00000000,
      0b00000000,
      # LUT4 - VCOM
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,

      # Duration            |  Repeat
      # A   B     C     D   |
      # 0 Flash
      64,
      12,
      32,
      12,
      6,
      # 1 clear
      16,
      8,
      4,
      4,
      6,
      # 2 bring in the black
      4,
      8,
      8,
      16,
      16,
      # 3 time for red
      2,
      2,
      2,
      64,
      32,
      # 4 final black sharpen phase
      2,
      2,
      2,
      2,
      2,
      # 5
      0,
      0,
      0,
      0,
      0,
      # 6
      0,
      0,
      0,
      0,
      0
    >>
  end

  defp get_luts(:yellow) do
    <<
      # Phase 0     Phase 1     Phase 2     Phase 3     Phase 4     Phase 5     Phase 6
      # A B C D     A B C D     A B C D     A B C D     A B C D     A B C D     A B C D
      # LUT0 - Black
      0b11111010,
      0b10010100,
      0b10001100,
      0b11000000,
      0b11010000,
      0b00000000,
      0b00000000,
      # LUTT1 - White
      0b11111010,
      0b10010100,
      0b00101100,
      0b10000000,
      0b11100000,
      0b00000000,
      0b00000000,
      # IGNORE
      0b11111010,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      0b00000000,
      # LUT3 - Yellow (or Red)
      0b11111010,
      0b10010100,
      0b11111000,
      0b10000000,
      0b01010000,
      0b00000000,
      0b11001100,
      # LUT4 - VCOM
      0b10111111,
      0b01011000,
      0b11111100,
      0b10000000,
      0b11010000,
      0b00000000,
      0b00010001,

      # Duration            | Repeat
      # A   B     C     D   |
      64,
      16,
      64,
      16,
      8,
      8,
      16,
      4,
      4,
      16,
      8,
      8,
      3,
      8,
      32,
      8,
      4,
      0,
      0,
      16,
      16,
      8,
      8,
      0,
      32,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0
    >>
  end
end
