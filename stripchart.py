import time
import serial
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import sys, math
from matplotlib import colors

xsize=100

ser = serial.Serial(
 port='COM8',
 baudrate=115200,
 parity=serial.PARITY_NONE,
 stopbits=serial.STOPBITS_TWO,
 bytesize=serial.EIGHTBITS
)
ser.isOpen()

start_time = time.time()

# configure the serial port
def data_gen():
    time = data_gen.time
    while True:
        time+=1
        strin = ser.readline() # Get data from serial port
        strin = strin.rstrip() # Remove trailing characters from the string
        strin = strin.decode() # Change string encoding to utf-8 (compatible with ASCII)
        val=float(strin) # Convert to float
        yield time, val

def run(data):
    # update the data
    time,temp = data
    if time>-1:
        timedata.append(time)
        tempdata.append(temp)
        if time>xsize: # Scroll to the left.
            ax.set_xlim(time-xsize, time)
        line.set_data(timedata, tempdata)
        update_timer()
        ax.set_title(f'Temperature: {temp:.2f} °C')
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
ax = fig.add_subplot(111)
line, = ax.plot([], [], lw=2)
ax.set_ylim(-50, 300)
ax.set_xlim(0, xsize)
ax.grid()
timedata, tempdata = [], []

ani = animation.FuncAnimation(fig, run, data_gen, blit=False, interval=100, repeat=False)
plt.show()
