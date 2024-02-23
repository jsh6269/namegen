# Namegen Forward
##  CPU  
    Generating 20 names...Done!  
    First 8 results are: Karlen, Elisah, Devonda, Stephen, Christiano, Mikelle, Madaline, Benuel  
    Writing to output.txt ...Done!  
    Elapsed time: 1.527765 seconds  
    Throughput: 13.091 names/sec  
  
## GPU  
### command  
    ./run.sh model.bin output.txt {N} {random_seed}  

###  history
- implemented kernel function (2024.02.22.)  
- applied kernel fusion (2024.02.23.)<br><br>
  
###  sample  
- N = 16  
Elapsed time: 0.127301 seconds  
Throughput: 125.686 names/sec  

  
- N = 256  
Elapsed time: 1.756758 seconds  
Throughput: 145.723 names/sec  

  
- N = 4096  
Elapsed time: 27.662653 seconds  
Throughput: 148.070 names/sec  
  
- N = 8192  
Elapsed time: 55.304508 seconds  
Throughput: 148.125 names/sec  
  
