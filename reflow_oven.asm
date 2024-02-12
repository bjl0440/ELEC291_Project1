; Implementation of the finite state machine to control the stages of the reflow oven

$NOLIST
$MODN76E003
$LIST

;  N76E003 pinout:
;                               -------
;       PWM2/IC6/T0/AIN4/P0.5 -|1    20|- P0.4/AIN5/STADC/PWM3/IC3
;               TXD/AIN3/P0.6 -|2    19|- P0.3/PWM5/IC5/AIN6
;               RXD/AIN2/P0.7 -|3    18|- P0.2/ICPCK/OCDCK/RXD_1/[SCL]
;                    RST/P2.0 -|4    17|- P0.1/PWM4/IC4/MISO
;        INT0/OSCIN/AIN1/P3.0 -|5    16|- P0.0/PWM3/IC3/MOSI/T1
;              INT1/AIN0/P1.7 -|6    15|- P1.0/PWM2/IC2/SPCLK
;                         GND -|7    14|- P1.1/PWM1/IC1/AIN7/CLO
;[SDA]/TXD_1/ICPDA/OCDDA/P1.6 -|8    13|- P1.2/PWM0/IC0
;                         VDD -|9    12|- P1.3/SCL/[STADC]
;            PWM5/IC7/SS/P1.5 -|10   11|- P1.4/SDA/FB/PWM1
;                               -------
;

CLK           EQU 16600000 ; Microcontroller system frequency in Hz
BAUD          EQU 115200 ; Baud rate of UART in bps
TIMER0_RATE   EQU 2048     ; 2048Hz squarewave (peak amplitude of CEM-1203 speaker)
TIMER1_RELOAD EQU (0x100-(CLK/(16*BAUD)))
TIMER0_RELOAD EQU ((65536-(CLK/TIMER0_RATE)))
TIMER2_RATE   EQU 100      ; 100Hz or 10ms
TIMER2_RELOAD EQU (65536-(CLK/(16*TIMER2_RATE))) ; Need to change timer 2 input divide to 16 in T2MOD

; Relevant vectors
; Reset vector
org 0x0000
    ljmp initialize

; Timer/Counter 0 overflow interrupt vector
org 0x000B
	ljmp Timer0_ISR

; Timer/Counter 2 overflow interrupt vector
org 0x002B
	ljmp Timer2_ISR
	
	
;;;;;;;;;;;;
;   PINS   ;
;;;;;;;;;;;;
   
LCD_RS     equ P1.3
;LCD_RW    equ PX.X  ; Not used in this code, connect the pin to GND
LCD_E      equ P1.4
LCD_D4     equ P0.0
LCD_D5     equ P0.1
LCD_D6     equ P0.2
LCD_D7     equ P0.3   
PWM_OUT    equ P1.0 ; Toggles power to the oven (Logic 1=oven on)
SOUND_OUT  equ P0.4 ; Speaker connection 

; Decleration of one byte current state variable and parameters
DSEG at 0x30
Count1ms:      ds 2 ; Used to determine when a second has passed
soak_temp:     ds 2 ; User set variable for the desired soak temperature
soak_time:     ds 2 ; User set variable for the length of the soak time
reflow_temp:   ds 2 ; User set variable for the reflow temperature
reflow_time:   ds 1 ; User set variable for timein the reflow state
current_temp:  ds 1 ; Current temperature in the oven
state_time:    ds 1 ; Current amount of time we have been in a given state
current_state: ds 1 ; Current state of the finite state machine
pwm_counter:   ds 1 ; Free running counter 0, 1, 2, ..., 100, 0 used for PWM purposes
pwm:           ds 1 ; pwm percentage variable - adjust as needed in each state

;for math_32.inc library
x:   ds 4
y:   ds 4
bcd: ds 5

; decleration of one bit variables (flags)
BSEG
; These one bit variables store the value of the pushbuttons after calling 'LCD_PB' 
PB0: 		   dbit 1 ; incremement (INC)
PB1: 		   dbit 1 ; decremement (DEC)
PB2: 		   dbit 1 ; next parameter (NXT)
PB3: 		   dbit 1 ; currently unused (PB3)
PB4: 		   dbit 1 ; start / emergency stop (EMR)
display_time:  dbit 1 ; if this flag is set, we want to start displaying the state time
next_state:    dbit 1 ; if this flag is set, we want to make a speaker beep
cooling_done:  dbit 1 ; flag set if cooling state is finished
mf:            dbit 1 ; used for math functions  

CSEG

; Strings
;                '1234567890123456'
initial_msg1: DB 'To=   C  Tj=20C ',0
initial_mgs2: DB 's1  ,   r2  ,   ',0
;         s=soak temp, soak time   r=reflow temp,reflow time

;state name messages
;                '1234567890123456'
preheat_mgs: DB    't=       Preheat',0
soak_mgs:    DB    't=       Soaking',0
ramp_mgs:    DB    't=          Ramp',0
reflow_mgs:  DB    't=        Reflow',0
cooling_mgs: DB    't=       Cooling',0


; A library of LCD related functions and utility macros
$NOLIST
$include(LCD_4bit.inc) 
$LIST

; A library of math related functions and utility macros
$NOLIST
$include(math32.inc)
$LIST

; Initialization of timers
;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 0                     ;
;---------------------------------;
Timer0_Init:
	orl CKCON, #0b00001000 ; Input for timer 0 is sysclk/1
	mov a, TMOD
	anl a, #0xf0 ; 11110000 Clear the bits for timer 0
	orl a, #0x01 ; 00000001 Configure timer 0 as 16-timer
	mov TMOD, a
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	; Enable the timer and interrupts
    setb ET0  ; Enable timer 0 interrupt
    setb TR0  ; Start timer 0
	ret

;---------------------------------;
; ISR for timer 0.  Set to execute;
; every 1/2048Hz to generate a    ;
; 2048 Hz wave at pin SOUND_OUT   ;
;---------------------------------;
Timer0_ISR:
	;clr TF0  ; According to the data sheet this is done for us already.
	; Timer 0 doesn't have 16-bit auto-reload, so
	clr TR0
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	setb TR0
	cpl SOUND_OUT ; Toggles the speaker pin at 1000 Hz to play noise
	reti

;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	; Initialize timer 2 for periodic interrupts
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	mov T2MOD, #0b1010_0000 ; Enable timer 2 autoreload, and clock divider is 16
	mov RCMP2H, #high(TIMER2_RELOAD)
	mov RCMP2L, #low(TIMER2_RELOAD)
	; Init the free running 10 ms counter to zero
	mov pwm_counter, #0
	; Enable the timer and interrupts
	orl EIE, #0x80 ; Enable timer 2 interrupt ET2=1
    setb TR2  ; Enable timer 2
	setb EA ; Enable global interrupts

	ret 

;---------------------------------;
; ISR for timer 2                 ;
;---------------------------------;
Timer2_ISR:
	clr TF2  ; Timer 2 doesn't clear TF2 automatically. Do it in the ISR.  It is bit addressable.
	push psw
	push acc
	
	inc pwm_counter
	clr c
	mov a, pwm
	subb a, pwm_counter ; If pwm_counter <= pwm then c=1
	cpl c
	mov PWM_OUT, c
	
	mov a, pwm_counter
	cjne a, #100, Timer2_ISR_done ; check if 1000 ms have passed
	mov pwm_counter, #0
	inc state_time ; It is super easy to keep a seconds count here

	jnb display_time, new_state_noise ; if we are in at least the pre-heat state, begin showing state time on the LCD	Set_Cursor(2,3)
	mov a, state_time
	da a 
	mov state_time, a 
	Set_Cursor(2,3)
	Display_BCD(state_time)

	new_state_noise:
	jnb next_state, send_serial ; if we are not entering a new state, jump to the send serial port code
	cpl TR0 ; Enable/disable timer/counter 0. This line enables the beep sound from the speaker when we enter a new state
	jb cooling_done, send_serial ; if cooling is done, we play the sound 3 times
	clr next_state

	send_serial:
	Send_BCD(x) ; Assuming the current temperature is stored in a byte of x

Timer2_ISR_done:
	pop acc
	pop psw
	reti

; Function declearations begins here:
; We can display a number any way we want.  In this case with four decimal places.
Display_formated_BCD:
	Set_Cursor(2, 5)
	Display_BCD(bcd+4)
	Display_BCD(bcd+3)
	Display_BCD(bcd+2)
	;Display_char(#'.')
	Display_BCD(bcd+1)
	Display_BCD(bcd+0)
	Set_Cursor(2, 6)
	
	ret

Read_ADC:
	clr ADCF
	setb ADCS ;  ADC start trigger signal
    jnb ADCF, $ ; Wait for conversion complete
    
    ; Read the ADC result and store in [R1, R0]
    mov a, ADCRL
    anl a, #0x0f
    mov R0, a
    mov a, ADCRH   
    swap a
    push acc
    anl a, #0x0f
    mov R1, a
    pop acc
    anl a, #0xf0
    orl a, R0
    mov R0, A
	ret


; this function reads the overall temperature
; (cold + hot) junction and turns the value in bcd
Read_Temp:
	; Read the signal connected to AIN7
	anl ADCCON0, #0xF0
	orl ADCCON0, #0x07 ; Select channel 7
Average_ADC:
	Load_x(0)
	mov r5, #100
Sum_loop0:
	lcall Read_ADC
    
    ; Convert to voltage
	mov y+0, R0
	mov y+1, R1
	mov y+2, #0
	mov y+3, #0

	lcall add32
	djnz r5, Sum_loop0

	Load_y(100)
	lcall div32

	Load_y(51400) ; VCC voltage measured
	lcall mul32
	Load_y(4095) ; 2^12-1
	lcall div32

	Load_y(1000)
	lcall mul32

	Load_y(100)
	lcall mul32

	Load_y(90909)
	lcall div32

	Load_y(41)
	lcall div32

	Load_y(20)
	lcall add32

	Load_y(10000)
	lcall mul32

	; Convert to BCD and display
	lcall hex2bcd
	;Set_Cursor(1, 13)
	;Display_BCD(bcd+3)
	;Display_BCD(bcd+2)
	;Display_char(#'.')
	;Display_BCD(bcd+1)
	;Display_BCD(bcd+0)
	
	; Wait 50 ms between conversions
	mov R2, #50
	lcall waitms

	ret

;------------------------------------;
; Check for pushbutton press         ;
;------------------------------------;
LCD_PB:
	; Set variables to 1: 'no push button pressed'
	setb PB0
	setb PB1
	setb PB2
	setb PB3
	setb PB4
	; The input pin used to check set to '1'
	setb P1.5
	
	; Check if any push button is pressed
	clr P0.0
	clr P0.1
	clr P0.2
	clr P0.3
	clr P1.3
	jb P1.5, LCD_PB_Done

	; Debounce
	mov R2, #50
	lcall waitms
	jb P1.5, LCD_PB_Done

	; Set the LCD data pins to logic 1
	setb P0.0
	setb P0.1
	setb P0.2
	setb P0.3
	setb P1.3
	
	; Check the push buttons one by one
	clr P1.3
	mov c, P1.5
	mov PB0, c
	setb P1.3

	clr P0.0
	mov c, P1.5
	mov PB1, c
	setb P0.0
	
	clr P0.1
	mov c, P1.5
	mov PB2, c
	setb P0.1
	
	clr P0.2
	mov c, P1.5
	mov PB3, c
	setb P0.2
	
	clr P0.3
	mov c, P1.5
	mov PB4, c
	setb P0.3

	; If a button was pressed, set the flag
	mov R3, #1

LCD_PB_Done:		
	ret

;---------------------------------;
; Wait 'R2' milliseconds          ;
;---------------------------------;
waitms:
    push AR0
    push AR1
L6: mov R1, #40
L5: mov R0, #104
L4: djnz R0, L4 ; 4 cycles->4*60.24ns*104=25.0us
    djnz R1, L5 ; 25us*40=1.0ms
    djnz R2, L6 ; number of millisecons to wait passed in R2
    pop AR1
    pop AR0
    ret


; Main program code begins here!
initialize:

	;;;;;;;;;;;;;;;;;;;
	;; CONFIGURATION ;;
	;;;;;;;;;;;;;;;;;;;

	; Configure all the pins for biderectional I/O
	mov	P3M1, #0x00
	mov	P3M2, #0x00
	mov	P1M1, #0x00
	mov	P1M2, #0x00
	mov	P0M1, #0x00
	mov	P0M2, #0x00

	; The following code initializes the serial port
	orl	CKCON, #0x10 ; CLK is the input for timer 1
	orl	PCON, #0x80 ; Bit SMOD=1, double baud rate
	mov	SCON, #0x52
	anl	T3CON, #0b11011111
	anl	TMOD, #0x0F ; Clear the configuration bits for timer 1
	orl	TMOD, #0x20 ; Timer 1 Mode 2
	mov	TH1, #TIMER1_RELOAD ; TH1=TIMER1_RELOAD;
	setb TR1

	; Initialize the pin used by the ADC (P1.1) as input.
	orl	P1M1, #0b00000010
	anl	P1M2, #0b11111101
	
	; Initialize and start the ADC:
	anl ADCCON0, #0xF0
	orl ADCCON0, #0x07 ; Select channel 7
	; AINDIDS select if some pins are analog inputs or digital I/O:
	mov AINDIDS, #0x00 ; Disable all analog inputs
	orl AINDIDS, #0b10000000 ; P1.1 is analog input
	orl ADCCON1, #0x01 ; Enable ADC
	
	; Initialize the Timers
    lcall Timer0_Init ; Timer 1 (used to play noise from the speaker)
    lcall Timer2_Init ; Timer 2 (used to trigger an ISR every 1 second)

	; Initialize the LCD - Toggle the 'E' pin
    lcall LCD_4BIT ; Initialize the LCD display in 4 bit mode
	;cpl TR0 ; toggle timer 0 immediately, or else it will make noise right away!

	; Display the initial strings
    Set_Cursor(1,1)
    Send_Constant_String(#initial_msg1)

    Set_Cursor(2,1)
    Send_Constant_String(#initial_mgs2)
	
	; Set the following variables to zero on startup
	mov a, #0x0
	da a
	mov current_state, a
	mov display_time, a
	mov a, #0x30
	da a
	mov soak_temp, a
	mov a, #0x60
	da a
	mov soak_time, a
	mov a, #0x00
	da a
	mov reflow_temp, a
	mov a, #0x45
	da a
	mov reflow_time, a


;;;;;;;;;;;;;;;;;;;;;;;;
; FINITE STATE MACHINE ;
;;;;;;;;;;;;;;;;;;;;;;;;

; Start of the finite state machine
FSM1: 
	mov current_state , #0x00


; STATE 0 - Off State (power 0%)
off_state:
	 
	setb TR2 ; Start Timer 2

	mov pwm, #0 ; set the oven power to 0 in this state
	
	clr cooling_done
	setb next_state ; play sound out of the speaker 

	; set the initial values on the screen
	Set_Cursor(2,3) ; display the initial soak temperature
	Display_BCD(soak_temp+0)

	Set_Cursor(2,7) ; display the initial soak time
	Display_BCD(soak_time+0)

	Set_Cursor(2,11) ; display the initial reflow temperature
	Display_BCD(reflow_temp+0)

	Set_Cursor(2,14) ; display the initial reflow time
	Display_BCD(reflow_time+0)

	; we first want the user to set the soak temperature
	soak_temp_button:
	lcall LCD_PB ; check for pushbutton presses
	mov r2, #50
	lcall waitms
	lcall LCD_PB 
	
	jnb PB0, inc_soak_temp ; if the increment button is pressed
	jnb PB1, dec_soak_temp ; if the decrement button is pressed
	jnb PB2, soak_time_button ; if the next button is pressed
	sjmp display_soak_temp ; check button presses again

	inc_soak_temp:
	mov a, soak_temp+0
	add a, #0x01
	da a
	cjne a, #0x70, continue1
	mov soak_temp+0, #0x30
	sjmp display_soak_temp

	dec_soak_temp:
	mov a, soak_temp+0
	add a, #0x99
	da a
	cjne a, #0x29, continue1
	mov soak_temp+0, #0x70
	sjmp display_soak_temp

	continue1:
	mov soak_temp+0, a
	sjmp display_soak_temp
	
	display_soak_temp:
	Set_Cursor(2,3) ; display the current soak temperature
	Display_BCD(soak_temp+0)
	sjmp soak_temp_button

	; next we want to user the set the soak time (in seconds)
	soak_time_button:
	lcall LCD_PB ; check for pushbutton presses
	mov r2, #50
	lcall waitms
	lcall LCD_PB
	
	jnb PB0, inc_soak_time ; if the increment button is pressed
	jnb PB1, dec_soak_time ; if the decrement button is pressed
	jnb PB2, reflow_temp_button ; if the next button is pressed
	sjmp display_soak_time ; check button presses again

	inc_soak_time:
	mov a, soak_time+0 
	add a, #0x01
	da a
	mov soak_time, a
	sjmp display_soak_time

	dec_soak_time:
	mov a, soak_time+0
	add a, #0x99
	da a
	mov soak_time, a
	
	display_soak_time:
	Set_Cursor(2,7) ; display the current soak time
	Display_BCD(soak_time+0)
	sjmp soak_time_button

	; third, we want the user to set the reflow temperature 
	reflow_temp_button:
	lcall LCD_PB ; check for pushbutton presses
	mov r2, #50
	lcall waitms
	lcall LCD_PB
	
	jnb PB0, inc_reflow_temp ; if the increment button is pressed
	jnb PB1, dec_reflow_temp ; if the decrement button is pressed
	jnb PB2, reflow_time_button ; if the next button is pressed
	sjmp reflow_temp_button ; check button presses again

	inc_reflow_temp:
	mov a, reflow_temp+0
	add a, #0x01
	da a
	cjne a, #0x50, continue3
	mov reflow_temp+0, #0x00
	mov reflow_temp+0, a
	sjmp display_reflow_temp

	dec_reflow_temp:
	mov a, reflow_temp
	add a, #0x99
	da a
	cjne a, #0x50, continue3
	mov reflow_temp+0, #0x50
	sjmp display_reflow_temp

	continue3:
	mov reflow_temp+0, a
	sjmp display_reflow_temp
	mov reflow_temp+0, a 

	display_reflow_temp:
	Set_Cursor(2,11) ; display the current reflow temperature
	Display_BCD(reflow_temp+0)
	sjmp reflow_temp_button

	; finally, we want the user to set the reflow time 
	reflow_time_button:
	lcall LCD_PB ; check for pushbutton presses
	mov r2, #50
	lcall waitms
	lcall LCD_PB
	
	jnb PB0, inc_reflow_time ; if the increment button is pressed
	jnb PB1, dec_reflow_time ; if the decrement button is pressed
	jnb PB2, wait_for_start ; if the next button is pressed
	sjmp reflow_time_button ; check button presses again

	inc_reflow_time:
	mov a, reflow_time
	add a, #0x01
	da a
	cjne a, #0x80, continue4
	mov reflow_time, #0x40
	sjmp display_reflow_time

	dec_reflow_time:
	mov a, reflow_time
	add a, #0x99
	da a
	cjne a, #0x39, continue4
	mov reflow_time, #0x80
	sjmp display_reflow_time

	continue4:
	mov reflow_time, a
	sjmp display_reflow_time
	mov reflow_time, a 

	display_reflow_time:
	Set_Cursor(2,14) ; display the current reflow time
	Display_BCD(reflow_time)
	sjmp reflow_time_button 

	; if we reach this label, all paramters have been set
	; we are now waiting for the user to press the start/stop button (PB4) to begin
	wait_for_start:
	lcall LCD_PB ; check for pushbuttons presses
	mov r2, #50
	lcall waitms
	lcall LCD_PB
	jb PB4, wait_for_start ; infinite loop if the start button is not pressed
	ljmp preheat_state
	;mov current_state, #1 ; if the start button is pressed, move to state 1 (preheat)


; STATE 1 - Preheat State (increase temperature to soak_temp - power 100%), check for it to reach over 50 C within 60 seconds
preheat_state:

	WriteCommand(#0x01) ; clear the LCD
	Set_Cursor(1,1)
    Send_Constant_String(#initial_msg1)
	mov pwm, #100 ; set the oven power to 100% in this state

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state
	setb display_time

	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#preheat_mgs)

	mov y+0, soak_temp+0
	mov y+1, soak_temp+1
	mov y+2, #0
	mov y+3, #0

	; check if the current temperature is equal to the user set soak temperature
	check_soak_temp:
	lcall Read_Temp 
	lcall x_gt_y ; sets the mf bit if x > y
	jb mf, preheat_state_done ; if we have reached the soak_temp, check for an error 

	; check if the current temperature is less than 50 degrees
	check_for_error:
	load_y(50)
	lcall x_gt_y ; check if the current temperature is greater than 50 degrees
	jb mf, check_soak_temp ; if we are over 50 degrees, check the temperature again

	; if the current temperature is less than 50 degrees, check the state time
	error: 
	mov a, state_time
	subb a, #60
	jc soak_not_reached ; if less than 60 seconds have passed, we have not reached the termination condition
	ljmp off_state ; if at least 60 seconds have passed, we must terminate the program 

	; if we are not ready to procede to soak, check the stop button
	soak_not_reached:

	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_soak_temp 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state

	preheat_state_done: 
	mov current_state, #2


; STATE 2 - Soak State (maintain temperature - power 20%)
soak_state: 

	mov a, current_state
	cjne a, #2, ramp_state ; if current state is not 0, move to state 1
	mov pwm, #20 ; set the oven power to 20% in this state

	WriteCommand(#0x01) ; clear the LCD
	Set_Cursor(1,1)
    Send_Constant_String(#initial_msg1)
	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#soak_mgs)

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state
	
	; check if the state_time is equal to the user set soak_time
	check_soak_time:
	mov a, state_time
	subb a, soak_time
	jc  ramp_not_reached ; if have not yet hit then soak_time, check if the stop button has been pressed
	jnc soak_state_done ; if the state_time is equal or greater to the soak_time, proceed to the ramp state

	; if we are not ready to procede to ramp to reflow, check the stop button
	ramp_not_reached:
	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_soak_time 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state 

	soak_state_done:
	mov current_state, #3


; STATE 3 - Ramp to Reflow State (increase temperature to reflow_temp - power 100%)	
ramp_state:

	mov a, current_state
	cjne a, #3, reflow_state ; if current state is not 3, move to state 4
	mov pwm, #100 ; set the oven power to 100% in this state
	
	; reset the state_time
	clr a
	mov state_time, a
	setb next_state

	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#ramp_mgs)


	check_ramp_temp: 
	; fetch the current temperature 
	lcall Read_Temp
	; moving the bcd value into current_temp
	mov current_temp, x+2

	; check if the current temperature is equal to the user set soak temperature
	mov a, current_temp
	subb a, reflow_temp
	jc reflow_not_reached ; if have not yet hit the reflow temperature, check if the stop button is pressed
	jnc ramp_state_done  ; if the current temperature is equal or greater to the reflow_temp, the ramp state is done

	; if we are not ready to procede to reflow, check the stop button
	reflow_not_reached:
	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_ramp_temp 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state

	ramp_state_done: 
	mov current_state, #4



; STATE 4 - Reflow State (maintain temperature - power 20%)
reflow_state:

	mov a, current_state
	cjne a, #4, cooling ; if current state is not 4, move to state 5
	mov pwm, #20 ; set the oven power to 20% in this state

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state

	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#reflow_mgs)

	; check if the state_time is equal to the user set reflow_time
	check_reflow_time:
	mov a, state_time
	subb a, reflow_time
	jc  cooling_not_reached ; if we have not yet hit the reflow_time, check if the stop button has been pressed
	jnc reflow_state_done ; if the state_time is equal or greater to the reflow_time, proceed to the cooling state

	; if we are not ready to procede to ramp to reflow, check the stop button
	cooling_not_reached:
	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_reflow_time 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state 

	reflow_state_done:
	mov current_state, #5


; STATE 5 - Cooling (power fully off)
cooling:

	mov pwm, #0 ; set the oven power to 0% in this state

	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#cooling_mgs)

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state

	check_cooling_temp: 
	; fetch the current temperature 
	lcall Read_Temp
	; moving the bcd value into current_temp
	mov current_temp, bcd+2

	; check if the current temperature is equal to the user set soak temperature
	mov a, current_temp
	subb a, #60
	jc cooling_state_done ; if the current temperature is less than 60 degrees, we have finished the cooling stage
	jnc check_cooling_temp  ; if the current temperature is greater than or equal to 60 degrees, check the temperature again

	cooling_state_done:
	mov current_state, #0
	clr display_time
	mov state_time, #0

	loop:
	mov a, state_time
	subb a, #6 ; wait 6 seconds - 2 second period for each speaker play
	jc loop ; condition not yet met
	ljmp off_state ; FSM done 
