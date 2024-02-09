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
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/TIMER2_RATE)))

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

; Decleration of one byte current state variable and parameters
DSEG 
Count1ms:      ds 2 ; Used to determine when a second has passed
soak_temp:     ds 1 ; User set variable for the desired soak temperature
soak_time:     ds 1 ; User set variable for the length of the soak time
reflow_temp:   ds 1 ; User set variable for 
reflow_time:   ds 1 ; User set variable for time above 217 degrees
current_temp:  ds 1 ; Current temperature in the oven
state_time:    ds 1 ; Current amount of time we have been in a given state

; decleration of one bit variables (flags)
BSEG
; These five bit variables store the value of the pushbuttons after calling 'LCD_PB' 
PB0: dbit 1 ; incremement (INC)
PB1: dbit 1 ; decremement (DEC)
PB2: dbit 1 ; next parameter (NXT)
PB3: dbit 1 ; currently unused (PB3)
PB4: dbit 1 ; emergency stop button (EMR)

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
	cpl SOUND_OUT ; Connect speaker the pin assigned to 'SOUND_OUT'!
	reti

;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	orl T2MOD, #0x80 ; Enable timer 2 autoreload
	mov RCMP2H, #high(TIMER2_RELOAD)
	mov RCMP2L, #low(TIMER2_RELOAD)
	; Init One millisecond interrupt counter.  It is a 16-bit variable made with two 8-bit parts
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
    mov one_second_flag, a
	; Enable the timer and interrupts
	orl EIE, #0x80 ; Enable timer 2 interrupt ET2=1
	ret

;---------------------------------;
; ISR for timer 2                 ;
;---------------------------------;
Timer2_ISR:
    clr TF2  ; Timer 2 doesn't clear TF2 automatically, so we reset it here!

	push acc ; The two registers used in the ISR must be saved in the stack. We use the 'push' instruction
	push psw

    ; Increment the 16-bit one ms counter
	inc Count1ms+0    ; Increment the low 8-bits first
	mov a, Count1ms+0 ; If the low 8-bits overflow, then increment high 8-bits
	jnz Inc_Done
	inc Count1ms+1

    Inc_Done:
    ; Next, we check if Count1ms has reached 1000 yet (equivalent to 1 second)
	mov a, Count1ms+0
	cjne a, #0xE8, Timer2_ISR_done ; checks if the lower byte of Count1ms is equal to the lower byte of 1000 
	mov a, Count1ms+1
	cjne a, #0x03, Timer2_ISR_done ; checks if the higher byte of Count1ms is equal to the higher byte of 1000 
    setb DoneFlag

    ; if the code continues to here, this means that 1 second has passed:
    ; Increment the state time variable 
	inc state_time+0    ; Increment the low 8-bits first
	mov a, Counstate_time+0 ; If the low 8-bits overflow, then increment high 8-bits
	jnz Inc_Done
	inc state_time+1
    
    Timer2_ISR_done:
    clr DoneFlag ; Clear the flag for the next interrupt
	pop psw 
	pop acc
	reti



; Strings
;                '1234567890123456'

initial_msg1: DB 'To=   C  Tj=  C ',0
initial_mgs2: DB 's   ,   r   ,   ',0
;         s=soak temp, soak time   r=reflow temp,reflow time

working_mgs: DB 't=               ',0
;                  at (2,7), write the state

; Display the initial strings - Initialize LCD and Timers
set_display:

    lcall Timer0_Init ; Initialize Timer 1 (used to play noise when the alarm goes off)
    lcall Timer2_Init ; Initialize Timer 2 (used to trigger an ISR every 1 second)
    setb EA   ; Enable Global interrupts
    lcall LCD_4BIT ; Initialize the LCD display in 4 bit mode

    Set_Cursor(1,1)
    Send_Constant_String(#initial_msg1)

    Set_Cursor(2,1)
    Send_Constant_String(#initial_mgs2)


; Initial State to set parameters (and Emergency Stop state)
; Also check for no temperature change in first 60 seconds reset
initial_state:

















; Preheat State (increase temperature to soak_temp - power 100%) 
preheat_state:
; Start Timer 2
setb TR2

check_soak_temp:
; Check the temperature

; Compare the temperature is less than soak_temp
mov a, current_temp 
cjne a, soak_temp, soak_temp_not_reached

; if the soak temp has been reached, move to the soak state
sjmp soak_state 

; If we reach this branch, the soak temperature has not yet been reached
soak_temp_not_reached:
; Check if the time has reached 60s. If so, there is an error so we terminate
cjne state_time, #0x3C, no_error

no_error:
; Check if the emergency stop button has been pressed
jnb EMR, emergency_stop ; jump if the button has been pressed


; If the emergency stop has not been pressed, loop back and check the temperature again
sjmp check_soak_temp




soak_state












































; Soak State (maintain temperature - power 20%)

; Ramp to Reflow State (increase temperature to reflow_temp - power 100%)

; Reflow State (maintain temperature - power 20%)

; Cooling (power fully off)

