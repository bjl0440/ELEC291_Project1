import time
from time import sleep
import serial
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import sys, math
from matplotlib import colors
from playsound import playsound
from tqdm import tqdm
import multiprocessing
from datetime import datetime
import threading

xsize = 700
progress_limit = 1
progress_bot = 0
ser = serial.Serial(
    port='COM14',
    baudrate=115200,
    parity=serial.PARITY_NONE,
    stopbits=serial.STOPBITS_TWO,
    bytesize=serial.EIGHTBITS
)
ser.isOpen()

state = 'A'
progress_bot = 0
start_time = time.time()
rtemp = int(input("reflow temp: "))
rtime = int(input("reflow time: "))
stemp = int(input("soak temp: "))
stime = int(input("soak time: "))
progress_rect = plt.Rectangle((0, 0), progress_bot, 50, facecolor='green', alpha=0.5)


# configure the serial port
def data_gen():
    global state,progress_limit,progress_bot
    time = data_gen.time
    prev_state = 'X'
    while True:
        time += 1
        strin = ser.readline()  # Get data from serial port
        strin = strin.rstrip()  # Remove trailing characters from the string
        strin = strin.decode()  # Change string encoding to utf-8 (compatible with ASCII)

        curr_state = strin[0]
        curr_temp = int(strin[1:])
        print(curr_state)
        val = float(curr_temp)  # Convert to float
        if curr_state == 'A':  # start
            if prev_state != 'A':
                
                progress_limit = stemp
                progress_bot = curr_temp
            else:
                progress_rect.set_width(curr_temp)

        elif curr_state == 'B':  # start

            if prev_state != 'B':
                counter = datetime.now()
                progress_limit = stime
                progress_bot = 0
            else:
                progress_rect.set_width(int((datetime.now() - counter).total_seconds()))

        elif curr_state == 'C':  # start
            if prev_state != 'C':
                progress_limit = rtemp
                progress_bot = curr_temp
            else:
                progress_rect.set_width(curr_temp)

        elif curr_state == 'D':  # start
            if prev_state != 'D':
                counter = datetime.now()
                progress_limit = rtime
                progress_bot = 0
            else:
                progress_rect.set_width(int((datetime.now() - counter).total_seconds()))
        elif curr_state == 'E':  # start
            if prev_state != 'E':
                progress_limit = curr_temp
                progress_bot = 60
            else:
                progress_rect.set_width(curr_temp)     
        else:
            progress_limit = 0
            progress_bot = 0  
        prev_state = curr_state
        yield time, val

def run(data):
    # update the data
    time, temp = data
    if time > -1:
        timedata.append(time)
        tempdata.append(temp)
        if time > xsize:  # Scroll to the left.
            ax.set_xlim(time - xsize, time)
        line.set_data(timedata, tempdata)
        update_timer()
        if(data[1] <= 10):
            line.set_color('skyblue')
        elif(10< data[1] <= 20):
            line.set_color('deepskyblue')
        elif(20<data[1]<=40):
            line.set_color('royalblue')
        elif(40< data[1] <= 60):
            line.set_color('turquoise')      
        elif(60< data[1] <= 80):
            line.set_color('greenyellow')
        elif(80< data[1] <= 120):
            line.set_color('yellow')
        elif(120< data[1] <= 160):
            line.set_color('orange')
        elif(160< data[1] <= 200):
            line.set_color('orangered')
        elif(200< data[1] <= 240):
            line.set_color('red')
        elif(240< data[1] <= 300):
            line.set_color('firebrick')
        else:
            line.set_color('black')

        ax2.set_xlim(0, progress_limit)

        ax.set_title(f'Temperature: {temp:.2f} °C')
        
        # Increment the width of the progress bar by 1 unit each second
    return line, 

def update_timer():
    elapsed_time = time.time() - start_time
    current_time = time.strftime("%H:%M:%S", time.gmtime(elapsed_time))
    fig.suptitle(f'Time Elapsed: {current_time}', fontsize=12)

def on_close_figure(event):
    sys.exit(0)

data_gen.time = -1
fig = plt.figure()
fig.canvas.mpl_connect('close_event', on_close_figure)
ax = fig.add_subplot(211)
line, = ax.plot([], [], lw=2)
ax.set_ylim(-50, 300)
ax.set_xlim(0, xsize)
ax.grid()
timedata, tempdata = [], []

ax2 = fig.add_subplot(212)
ax2.set_ylim(0, 1)
ax2.set_xlim(progress_bot, progress_limit)
ax2.grid(False)
plt.subplots_adjust(hspace=0.3)  
# Add a progress bar
ax2.add_patch(progress_rect)

ani = animation.FuncAnimation(fig, run, data_gen, blit=False, interval=100, repeat=False,)
plt.show()

