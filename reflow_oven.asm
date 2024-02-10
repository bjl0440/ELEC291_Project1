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
TIMER0_RATE   EQU 2048     ; 2048Hz squarewave (peak amplitude of CEM-1203 speaker)
TIMER0_RELOAD EQU ((65536-(CLK/TIMER0_RATE)))
TIMER2_RATE   EQU 100      ; 100Hz or 10ms
TIMER2_RELOAD EQU (65536-(CLK/(16*TIMER2_RATE))) ; Need to change timer 2 input divide to 16 in T2MOD

; Relevant vectors
; Reset vector
org 0x0000
    ljmp set_display

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
DSEG 
Count1ms:      ds 2 ; Used to determine when a second has passed
soak_temp:     ds 1 ; User set variable for the desired soak temperature
soak_time:     ds 1 ; User set variable for the length of the soak time
reflow_temp:   ds 1 ; User set variable for the reflow temperature
reflow_time:   ds 1 ; User set variable for timein the reflow state
current_temp:  ds 1 ; Current temperature in the oven
state_time:    ds 1 ; Current amount of time we have been in a given state
current_state: ds 1 ; Current state of the finite state machine
pwm_counter:   ds 1 ; Free running counter 0, 1, 2, ..., 100, 0 used for PWM purposes
pwm:           ds 1 ; pwm percentage variable - adjust as needed in each state

; decleration of one bit variables (flags)
BSEG
; These one bit variables store the value of the pushbuttons after calling 'LCD_PB' 
PB0: 		  dbit 1 ; incremement (INC)
PB1: 		  dbit 1 ; decremement (DEC)
PB2: 		  dbit 1 ; next parameter (NXT)
PB3: 		  dbit 1 ; currently unused (PB3)
PB4: 		  dbit 1 ; start / emergency stop (EMR)
display_time: dbit 1 ; if this flag is set, we want to start displaying the state time
new_state:    dbit 1 ; if this flag is set, we want to make a speaker beep


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
	cjne a, #100, Timer2_ISR_done
	mov pwm_counter, #0
	inc state_time ; It is super easy to keep a seconds count here
	setb s_flag

	jnb display_time, new_state_noise ; if we are in at least the pre-heat state, begin showing state time on the LCD	Set_Cursor(2,3)
	Set_Cursor(2,3)
	Display_BCD(state_time)

	new_state_noise:
	jnb new_state, Timer2_ISR_done ; if we are not entering a new state, end the ISR
	cpl TR0 ; Enable/disable timer/counter 0. This line creates a beep-silence-beep-silence sound.
	clr next_state

Timer2_ISR_done:
	pop acc
	pop psw
	reti


; Strings
;                '1234567890123456'
initial_msg1: DB 'To=   C  Tj=  C ',0
initial_mgs2: DB 's   ,   r   ,   ',0
;         s=soak temp, soak time   r=reflow temp,reflow time

working_mgs: DB 't=               ',0
;      at (2,3), display time,  at (2,7), write the state

;state name messages
;                '1234567890123456'
preheat_mgs:     't=       Preheat',0
soak_mgs:        't=       Soaking',0
ramp_mgs:        't=          Ramp',0
reflow_mgs:        't=          R',0

Reflo; Main program code begins here!
; Display the initial strings - Initialize LCD and Timers
set_display:

	; Configure all the pins for biderectional I/O
	mov	P3M1, #0x00
	mov	P3M2, #0x00
	mov	P1M1, #0x00
	mov	P1M2, #0x00
	mov	P0M1, #0x00
	mov	P0M2, #0x00

    lcall Timer0_Init ; Initialize Timer 1 (used to play noise from the speaker)
    lcall Timer2_Init ; Initialize Timer 2 (used to trigger an ISR every 1 second)
    lcall LCD_4BIT ; Initialize the LCD display in 4 bit mode
	cpl TR0 ; toggle timer 0 immediately, or else it will make noise right away!

    Set_Cursor(1,1)
    Send_Constant_String(#initial_msg1)

    Set_Cursor(2,1)
    Send_Constant_String(#initial_mgs2)
	
	clr current_state

; Start of the finite state machine
FSM1: 
	mov a, current_state 


; STATE 0 - Off State (power 0%)
off_state:
	setb TR2 ; Start Timer 2

	cjne a, #0, preheat_state ; if current state is not 0, move to state 1
	mov pwm, #0 ; set the oven power to 0 in this state
	
	setb next_state ; play sound out of the speaker 

	; we first want the user to set the soak temperature
	soak_temp_button:
	lcall LCD_PB ; check for pushbutton presses
	jnb PB0, inc_soak_temp ; if the increment button is pressed
	jnb PB1, dec_soak_temp ; if the decrement button is pressed
	jnb PB2, soak_time_button ; if the next button is pressed
	sjmp soak_temp_button ; check button presses again

	inc_soak_temp:
	inc soak_temp ; increment the soak temperature
	sjmp display_soak_temp

	dec_soak_temp:
	dec soak_temp ; decrement the soak temperature

	display_soak_temp:
	Set_Cursor(2,2) ; display the current soak temperature
	Display_BCD(soak_temp)
	sjmp soak_temp_button

	; next we want to user the set the soak time (in seconds)
	soak_time_button:
	lcall LCD_PB ; check for pushbutton presses
	jnb PB0, inc_soak_time ; if the increment button is pressed
	jnb PB1, dec_soak_time ; if the decrement button is pressed
	jnb PB2, reflow_temp_button ; if the next button is pressed
	sjmp soak_time_button ; check button presses again

	inc_soak_time:
	inc soak_time ; increment the soak time
	sjmp display_soak_time

	dec_soak_time:
	dec soak_time ; decrement the soak time
	
	display_soak_time:
	Set_Cursor(2,6) ; display the current soak time
	Display_BCD(soak_time)
	sjmp soak_time_button

	; third, we want the user to set the reflow temperature 
	reflow_temp_button:
	lcall LCD_PB ; check for pushbutton presses
	jnb PB0, inc_reflow_temp ; if the increment button is pressed
	jnb PB1, dec_reflow_temp ; if the decrement button is pressed
	jnb PB2, reflow_time_button ; if the next button is pressed
	sjmp reflow_temp_button ; check button presses again

	inc_reflow_temp:
	inc reflow_temp ; increment the soak time
	sjmp display_reflow_temp

	dec_reflow_temp:
	dec reflow_temp ; decrement the reflow temperature 

	display_reflow_temp:
	Set_Cursor(2,10) ; display the current reflow temperature
	Display_BCD(reflow_temp)
	sjmp reflow_temp_button

	; finally, we want the user to set the reflow time 
	reflow_time_button:
	lcall LCD_PB ; check for pushbutton presses
	jnb PB0, inc_reflow_time ; if the increment button is pressed
	jnb PB1, dec_reflow_time ; if the decrement button is pressed
	jnb PB2, wait_for_start ; if the next button is pressed
	sjmp reflow_time_button ; check button presses again

	inc_reflow_time:
	inc reflow_time ; increment the soak time
	sjmp display_reflow_time

	dec_reflow_time:
	dec reflow_time ; decrement the reflow temperature 

	display_reflow_time:
	Set_Cursor(2,10) ; display the current reflow temperature
	Display_BCD(reflow_temp)
	sjmp reflow_time_button 

	; if we reach this label, all paramters have been set
	; we are now waiting for the user to press the start/stop button (PB4) to begin
	wait_for_start:
	lcall LCD_PB ; check for pushbuttons presses
	jb PB4, wait_for_start ; infinite loop if the start button is not pressed
	mov current_state, #1 ; if the start button is pressed, move to state 1 (preheat)


; STATE 1 - Preheat State (increase temperature to soak_temp - power 100%), check for it to reach over 50 C within 60 seconds
preheat_state:

	cjne a, #1, soak_state ; if current state is not 1, move to state 2
	mov pwm, #100 ; set the oven power to 100% in this state

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state

	; display the working message string
	Set_Cursor(2,1)
    Send_Constant_String(#working_mgs)

	check_soak_temp: 
	; fetch the current temperature ***Not complete
	; check if the current temperature is less than 50 degrees
	; if the current temperature is less than 50 degrees, check the state time
	; if the state time is less than 60 seconds, terminate and return to state 0
	; if the termination condition is not met, check if the current temperature equals the soak temperature
	; if (current_temp > soak_temp), current_state = 2, ljmp to preheat_state_done; else ljmp soak_not_reached


	; if we are not ready to procede to soak, check the stop button
	soak_not_reached:
	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_soak_temp 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state

	preheat_state_done: 
	mov curren_state, #2


; STATE 2 - Soak State (maintain temperature - power 20%)
soak_state: 

	cjne a, #2, ramp_state ; if current state is not 0, move to state 1
	mov pwm, #20 ; set the oven power to 20% in this state

	; reset the state_time
	clr a
	mov state_time, a
	setb next_state

	; we stay in this state, with 20% power until state_time equals the soak_time variable
	check_soak_time:
	mov a, state_time
	cjne a, soak_time, ramp_not_reached
	sjmp soak_state_done

	; if we are not ready to procede to ramp to reflow, check the stop button
	ramp_not_reached:
	lcall LCD_PB ; check for pushbutton presses
	jb PB4, check_soak_time 
	mov current_state, #0 ; if the stop button is pressed, return to state 0
	ljmp off_state 

	soak_state_done:
	mov curren_state, #3


; STATE 3 - Ramp to Reflow State (increase temperature to reflow_temp - power 100%)	
ramp_state:

	cjne a, #3, reflow_state ; if current state is not 0, move to state 1
	mov pwm, #100 ; set the oven power to 100% in this state
	



















; STATE 4 - Reflow State (maintain temperature - power 20%)

; STATE 5 - Cooling (power fully off)





