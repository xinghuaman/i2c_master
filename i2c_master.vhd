--------------------------------------------------
--I2C master peripheral
--by Renan Picoli de Souza
--instantiates a generic I2C master and provides access to its registers 
--supports only 8 bit sending/receiving
-- NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_unsigned.all;
--use ieee.numeric_std.all;--to_integer
use work.my_types.all;--array32

entity i2c_master is
	port (
			D: in std_logic_vector(31 downto 0);--for register write
			ADDR: in std_logic_vector(1 downto 0);--address offset of registers relative to peripheral base address
			CLK: in std_logic;--for register read/write, also used to generate SCL
			RST: in std_logic;--reset
			WREN: in std_logic;--enables register write
			RDEN: in std_logic;--enables register read
			IACK: in std_logic;--interrupt acknowledgement
			Q: out std_logic_vector(31 downto 0);--for register read
			IRQ: out std_logic;--interrupt request
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
end i2c_master;

architecture structure of i2c_master is
	component address_decoder_register_map
	--N: address width in bits
	--boundaries: upper limits of each end (except the last, which is 2**N-1)
	generic	(N: natural);
	port(	ADDR: in std_logic_vector(N-1 downto 0);-- input
			RDEN: in std_logic;-- input
			WREN: in std_logic;-- input
			WREN_OUT: out std_logic_vector;-- output
			data_in: in array32;-- input: outputs of all peripheral/registers
			data_out: out std_logic_vector(31 downto 0)-- data read
	);
	end component;
	
	component d_flip_flop
		port (D:	in std_logic_vector(31 downto 0);
				rst:	in std_logic;--synchronous reset
				ENA:	in std_logic:='1';--enables writes
				CLK:in std_logic;
				Q:	out std_logic_vector(31 downto 0)  
				);
	end component;
	
	component i2c_master_generic
	generic (N: natural);--number of bits in each data written/read
	port (
			DR_out: in std_logic_vector(31 downto 0);--data to be transmitted
			DR_in_shift: out std_logic_vector(31 downto 0);--data received, will be shifted into DR
			DR_shift: out std_logic;--DR must shift left N bits to make room for new word
			ADDR: in std_logic_vector(7 downto 0);--slave address
			CLK_IN: in std_logic;--clock input, divided by 2 to generate SCL
			RST: in std_logic;--reset
			I2C_EN: in std_logic;--enables transfer to start
			WORDS: in std_logic_vector(1 downto 0);--controls number of words to receive or send
			IACK: in std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			IRQ: out std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
	end component;
	
	component interrupt_controller
	generic	(L: natural);--L: number of IRQ lines
	port(	D: in std_logic_vector(31 downto 0);-- input: data to register write
			CLK: in std_logic;-- input
			RST: in std_logic;-- input
			WREN: in std_logic;-- input
			RDEN: in std_logic;-- input
			IRQ_IN: in std_logic_vector(L-1 downto 0);--input: all IRQ lines
			IRQ_OUT: out std_logic;--output: IRQ line to cpu
			IACK_IN: in std_logic;--input: IACK line coming from cpu
			IACK_OUT: buffer std_logic_vector(L-1 downto 0);--output: all IACK lines going to peripherals
			output: out std_logic_vector(31 downto 0)-- output of register reading
	);

	end component;
	
	constant N: natural := 4;--number of bits in each data written/read
	signal read_mode: std_logic;
	signal words: std_logic_vector(1 downto 0);--00: 1 word; 01:2 words; 10: 3 words (unused); 11: 4 words
	signal all_i2c_irq: std_logic_vector(1 downto 0);--0: successfully transmitted all words; 1: NACK received
	signal all_i2c_iack: std_logic_vector(1 downto 0);--0: successfully transmitted all words; 1: NACK received
	
	signal irq_ctrl_Q: std_logic_vector(31 downto 0);
	signal irq_ctrl_rden: std_logic;-- not used, just to keep form
	signal irq_ctrl_wren: std_logic;
	
	signal DR_out: std_logic_vector(31 downto 0);--data transmitted/received
	signal DR_in:  std_logic_vector(31 downto 0);--data that will be written to DR
	signal DR_in_shift:  std_logic_vector(31 downto 0);--data received from I2C bus
	signal DR_shift:std_logic;--enables write value from I2C generic component (received from I2C bus)
	signal DR_wren:std_logic;--enables write value from D port
	signal DR_ena:std_logic;--DR ENA (enables DR write)
	
	signal CR_in: std_logic_vector(31 downto 0);--CR input
	signal CR_Q: std_logic_vector(31 downto 0);--CR output
	signal CR_wren:std_logic;
	signal CR_ena:std_logic;
	
	signal all_registers_output: array32 (2 downto 0);
	signal all_periphs_rden: std_logic_vector(2 downto 0);
	signal address_decoder_wren: std_logic_vector(2 downto 0);
begin

	read_mode <= CR_Q(0);
	
	i2c: i2c_master_generic
	generic map (N => N)
	port map(DR_out => DR_out,
				DR_in_shift  => DR_in_shift,
				DR_shift=> DR_shift,
				CLK_IN => CLK,
				ADDR => CR_Q(7 downto 0),
				RST => RST,
				I2C_EN => CR_Q(10),
				WORDS => CR_Q(9 downto 8),
				IACK => all_i2c_iack,
				IRQ => all_i2c_irq,
				SDA => SDA,
				SCL => SCL
	);
	
	irq_ctrl_wren <= address_decoder_wren(2);
	irq_ctrl_rden <= '1';--not necessary, just to keep form
	irq_ctrl: interrupt_controller
	generic map (L => 2)
	port map(D => D,
				CLK => CLK,
				RST => RST,
				WREN => irq_ctrl_wren,
				RDEN => irq_ctrl_rden,
				IRQ_IN => all_i2c_irq,
				IRQ_OUT => IRQ,
				IACK_IN => IACK,
				IACK_OUT => all_i2c_iack,
				output => irq_ctrl_Q
	);
	
	--data register: data to be transmited or received, or address
	DR_wren <= address_decoder_wren(1);
	DR_ena <= 	DR_shift when read_mode='1' else
					DR_wren;
	DR_in <= DR_out(31-N downto 0) & DR_in_shift(N-1 downto 0) when read_mode='1' else-- read mode (master receiver after address acknowledgement)
				D;-- write mode (master transmitter)
	
	DR: d_flip_flop port map(D => DR_in,
									RST=> RST,--resets all previous history of input signal
									CLK=> CLK,--sampling clock
									ENA=> DR_ena,
									Q=> DR_out
									);
	
	--control register: 
	--bit 10: I2C_EN (write '1' to start, reset automatically)
	--bits 9:8 WORDS - 1 (MSByte first, MSB first);
	--bits 7:1 slave address;
	--bit 0: read (0) or write (1)
	CR_in <= D when CR_wren='1' else CR_Q(31 downto 11) & '0' & CR_Q(9 downto 0);
	CR_ena <= '1';
	CR_wren <= address_decoder_wren(0);
	CR: d_flip_flop port map(D => CR_in,
									RST=> RST,--resets all previous history of input signal
									CLK=> CLK,--sampling clock
									ENA=> CR_ena,
									Q=> CR_Q
									);

-------------------------- address decoder ---------------------------------------------------
	--addr 00: CR
	--addr 01: DR
	--addr 10: irq_ctrl (interrupts pending)
	all_registers_output <= (0=> CR_Q,1=> DR_out,2=> irq_ctrl_Q);
	decoder: address_decoder_register_map
	generic map(N => 2)
	port map(ADDR => ADDR,
				RDEN => RDEN,
				WREN => WREN,
				data_in => all_registers_output,
				WREN_OUT => address_decoder_wren,
				data_out => Q
	);
end structure;