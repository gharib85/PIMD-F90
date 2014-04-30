module InputOutput
use consts
use main_stuff
Implicit none 

contains
!----------------------------------------------------------------------------------!
!---------------- Read input file -------------------------------------------------
!----------------------------------------------------------------------------------!
subroutine read_input_file 

call getarg(1, finp)
narg = command_argument_count()
if (narg .eq. 0) then
	write(*,*) "ERROR: no input file argument."
	stop
endif 
open(11, file=finp, status='old')
read(11,*)read_method
read(11,*)fconfig
read(11,*)fsave
read(11,*)coord_out
read(11,*)vel_out
read(11,*)OUTPUTIMAGES
read(11,*)dip_out
read(11,*)Edip_out
read(11,*)TD_out
read(11,*)TP_out
read(11,*)CALC_RADIUS_GYRATION
read(11,*)PRINTFINALCONFIGURATION
read(11,*)pot_model 
read(11,*)Rc, rc1, eps_ewald
read(11,*)polar_maxiter, polar_sor, polar_eps, guess_initdip, print_dipiters
read(11,*)GENVEL
read(11,*)INPCONFIGURATION
read(11,*)THERMOSTAT
read(11,*)BEADTHERMOSTAT
read(11,*)CENTROIDTHERMOSTAT
read(11,*)bead_thermostat_type
read(11,*)tau
read(11,*)tau_centroid
read(11,*)global_chain_length
read(11,*)bead_chain_length
read(11,*)temp
read(11,*)BAROSTAT
read(11,*)tau_P
read(11,*)press 
read(11,*)BOXSIZEOUT		
read(11,*)PEQUIL
read(11,*)eq_timesteps
read(11,*)num_timesteps
read(11,*)delt
read(11,*)td_freq
read(11,*)tp_freq
read(11,*)ti_freq
read(11,*)t_freq
read(11,*)Nbeads
read(11,*)setNMfreq
read(11,*)massO
read(11,*)massH

SIMPLE_ENERGY_ESTIMATOR = .true.

close(11)  
end subroutine read_input_file 


!----------------------------------------------------------------------------------!
!---------------- Initialize some variables for all nodes -------------------------
!----------------------------------------------------------------------------------!
subroutine initialize_all_node_variables

!---  read the number of atoms, dimension of box and atomic coordinates --------- 
 open(10,file=fconfig,status='old')

 if (INPCONFIGURATION) then
	read(10,*) Natoms 
	read(10,*,IOSTAT=ierr) Upot, box(1:3)
	if (ierr .ne. 0) then 
		rewind(10)
		read(10,*) Natoms 
		read(10,*,IOSTAT=ierr) box(1:3)
		if (ierr .ne. 0) then 
			write(*,*) "ERROR: could not read box size from input file. Trying to continue anyway"
		endif 
	endif 

	Natoms = Natoms/Nbeads
 else 
	!usually the box size is in the first line of a raw .xyz
	!but it might be in the second line. 
	read(10,*,IOSTAT=ierr) Natoms, box(1:3)
	read(10,* ) 
	if (ierr .ne. 0) then 
		rewind(10)
		read(10,*) Natoms 
		read(10,*,IOSTAT=ierr) box(1:3)
		if (ierr .ne. 0) then 
			write(*,*) "ERROR: could not read box size from input file. Trying to continue anyway"
		endif
	endif 
 endif 


!These parameters are used later on  
Rc2 = Rc * Rc
Nwaters = Natoms/3
volume = box(1)*box(2)*box(3)
volume_init = volume
delt = delt/1000d0 !***CONVERT fs - > ps ***
delt2 = delt/2d0
boxi = 1.d0 / box
!inverse masses
imassO = DBLE(1/massO) 
imassH = DBLE(1/massH)
iNbeads = 1d0/DBLE(Nbeads)
CompFac = (.4477d-5*delt)/(tau_P) !Barostat var. (contains compressibility of H2O)
sum_temp = 0 
sum_press = 0 
sum_tot_energy = 0 
sum_simple_energy = 0 
sum_energy = 0
sum_energy2 = 0
sum_RMSenergy = 0
tt = 0 
tr = 0
counti = 3*Natoms
omegan = KB_amuA2ps2perK*temp*Nbeads/hbar
kTN = KB_amuA2ps2perK*temp*Nbeads
s = 1
sbead = 1

Nbatches = Nbeads/Nnodes

!--- Slave-node-only allocations ---- 
if (pid .ne. 0) then
	allocate(RR(3, Natoms))
	allocate(VV(3, Natoms))
	allocate(dRR(3, Natoms))
endif

!--- All-node allocations ------ 
allocate(dip_momI(3, Nwaters))
allocate(dip_momE(3, Nwaters))
allocate(chg (Natoms))
allocate(tx_dip(3,4*Nwaters, 4))

end subroutine initialize_all_node_variables


!----------------------------------------------------------------------------------!
!---------- Master node allocations -----------------------------------------------
!----------------------------------------------------------------------------------!
subroutine master_node_init
	use Langevin 
	use NormalModes

if (Nbeads .lt. 1) then 
	write(*,*) "ERROR : invalid number of beads!! " 
endif

if ( .not.( (bead_thermostat_type .eq. 'Langevin') .or. (bead_thermostat_type .eq. 'Nose-Hoover') &
	.or. (bead_thermostat_type .eq. 'none') ) ) then
		write(*,*) "ERROR: Invalid bead thermostat selection. Possible options: "
		write(*,*) "		'Nose-Hoover', 'Langevin', or 'none'  " 
	stop
endif

if ((CENTROIDTHERMOSTAT .or. BEADTHERMOSTAT) .and. (Nbeads .eq. 1)) then
	write(*,*) "WARNING: Bead/centroid thermostating does not make much sense with 1 bead."
	write(*,*) "The dynamics will be unphysical since every atomic DOF will be thermostated. "
endif

if (BEADTHERMOSTAT .and. .not. (THERMOSTAT)) then
	write(*,*) "WARNING: running bead thermostating without a global thermostat is not recommended."
	write(*,*) "You may observe abnormally large temperature fluctuations in the system."
endif

if (CENTROIDTHERMOSTAT.and. .not. (BEADTHERMOSTAT)) then
	write(*,*) "WARNING: You are thermostating the centroid but not thermostating the other modes."
	write(*,*) "There is not really any good reason for doing this. Consider a different scheme." 
endif

if (.not. ( (box(1).eq.box(2)) .and. (box(2).eq.box(3)) ) ) then
	write(*,*) 'ERROR: program can only handle square boxes.(it can be adapted for non-square but has not so far)'
	stop 
endif   

if ( Rc .gt. box(1)/2 ) then
	write(*,*) 'WARNING: cutoff radius is larger than half box size'
	stop
endif  

if (rc1 .lt. 0) then
 	write(*,*) "ERROR: start of shifted cutoff cannot be less than zero!!"
	stop
endif
if (Rc .lt. 0) then
 	write(*,*) "ERROR: Coloumb cutoff cannot be less than zero!!"
	stop
endif
if (rc1 .gt. Rc) then
 	write(*,*) "ERROR: start of shifted cutoff cannot be greater than Coloumb cuttoff!!"
	stop
endif
if ( (massH .lt. 0) .or. (massO .lt. 0)) then
 	write(*,*) "Invalid mass!!"
	stop
endif

if ( Nnodes .gt. Nbeads) then 
	write(*,*) "ERROR : The number of processors is greater than the number of beads! Assuming this is an error! "
	stop
endif

if (.not. (mod(Nbeads,Nnodes) .eq. 0)) then
	write(*,*) "ERROR: the number of beads must be a multiple of the number of nodes."
        write(*,'(a,i4,a,i4,a)') "To run on ", Nnodes, " nodes I suggest using ", Nbeads - mod(Nbeads,Nnodes), " beads"
	stop
endif


 
	!initialize random number generator
 	CALL RANDOM_SEED(size = m) !get size of seed for the system
 	ALLOCATE(seed(m))
	call system_clock(count=clock) 
	seed = clock + 357 * (/ (i - 1, i = 1, m) /)
 	call random_seed(put = seed)  !put in the seed
 		
	write(*,'(a,i4,a,i4,a)') "Running with ", Nbeads, " beads on ", Nnodes, " nodes"

	!Master node allocations
	!only the master node (pid = 0) stores a fully copy of the
	! coords / vel for all beads and the centroid
	allocate(RRt(3, Natoms,Nbeads))
	allocate(PPt(3, Natoms,Nbeads))
	allocate(dRRt(3, Natoms,Nbeads))
	allocate(dip_momIt(3, Nwaters,Nbeads))
	allocate(dip_momEt(3, Nwaters,Nbeads))
	allocate(Upott(Nbeads))
	allocate(RRc(3, Natoms))
	allocate(PPc(3, Natoms))
	dRRt = 0 

	call InitNormalModes(Nbeads, omegan, delt, setNMfreq)

	if (THERMOSTAT)  then
		allocate(vxi_global(global_chain_length))
		vxi_global = 1 !set chain velocities to zero initially
	endif 
	if (BEADTHERMOSTAT)  then
		allocate(vxi_beads(bead_chain_length,natoms,Nbeads,3))
		vxi_beads = 0 !set chain velocities to zero initially
	endif
	if (bead_thermostat_type .eq. 'Langevin') call Init_Langevin_NM(delt2, CENTROIDTHERMOSTAT, tau_centroid, Nbeads, temp)


end subroutine master_node_init

!----------------------------------------------------------------------------------!
!---------------- Read in coordinate data to RRc ----------------------------------
!----------------------------------------------------------------------------------!
subroutine read_coords

 if (INPCONFIGURATION) then 
	call load_configuration(10, RRt, PPt) 
 else 
 	if (read_method .eq. 0) then
        	do i=1, Nwaters
   		 	iO = 3*i-2 
 		 	read(10,*)ch2, RRc(1:3, iO)
  		enddo
   	 	do i=1, Nwaters
      			 ih1 = 3*i-1; ih2=3*i
     			 read(10,*)ch2, RRc(1:3, ih1)
      			 read(10,*)ch2, RRc(1:3, ih2)
  		 enddo
  	else if (read_method==1) then
   		do i=1, Natoms
     			 read(10,*)ch2, RRc(1:3, i)
  		enddo
	else 
		write(*,*) "Invalid read method!!"
		stop
	endif 
 endif

 close(10)
end subroutine read_coords


!-----------------------------------------------------------------------------------------
!--------------Open write out files -----------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine open_files
 if (coord_out) then
	open(20, file='out_'//TRIM(fsave)//'_coord.xyz', status='unknown')
 endif
 if (vel_out) then 	
	open(21, file='out_'//TRIM(fsave)//'_mom.dat', status='unknown')
 endif
 if (OUTPUTIMAGES) then
	open(27, file='out_'//TRIM(fsave)//'_images_coord.xyz', status='unknown')
 endif
 if  (dip_out) then
	open(22, file='out_'//TRIM(fsave)//'_dip.dat', status='unknown')
 endif
 if  (Edip_out) then
	open(26, file='out_'//TRIM(fsave)//'_Edip.dat', status='unknown')
 endif
 if (TD_out) then 
	open(23, file='out_'//TRIM(fsave)//'_tot_dip.dat', status='unknown')
 endif
 if (BOXSIZEOUT) then 
	open(25, file='out_'//TRIM(fsave)//'_box.dat', status='unknown')
 endif
 if (TP_out) then 
	TPoutStream = 24
	open(TPoutStream, file='out_'//TRIM(fsave)//'_TempPress.dat', status='unknown')
	write(*,*) "Supressing further terminal output to file"
 else 
	 TPoutStream = 6
 endif 

 !write header
 write(TPoutStream,'(a)') "all energies are in kcal/(mole H2O)"

 write(TPoutStream,'(a,a,a,a,a,a,a,a)',advance='no') " time (ps) ","  temp (K) ", "  press.(bar)  ", & 
		 "  avg temp  ","   avg press   ", "  Pot E   ","   Tot E   ","   avg Tot E   " 

 if (SIMPLE_ENERGY_ESTIMATOR) write(TPoutStream,'(a,a)',advance='no')  " Tot E (simple) ", " Avg tot E (simple) "
 if (CALC_RADIUS_GYRATION)    write(TPoutStream,'(a,a)',advance='no')  " r_O ", " r_H "

 write(TPoutStream,'(a)')  ""


end subroutine open_files



!----------------------------------------------------------------------------------!
!-------------- Calculate thermodynamic info and write out to file(s) -------------
!----------------------------------------------------------------------------------!
subroutine write_out 
 Implicit none 
!for accuracy, pressure is computed at every timestep, since P fluctuations are large
!total energy is also calculated every timestep
!in some cases, slight speedups were sacrificed for code readability 

	sys_temp = TEMPFACTOR*uk/(Natoms)

	!pressure / total energy calculation : classical case
	if (Nbeads .eq. 1) then

		sys_press = (1/(3*volume))*( 2*uk - MASSCON*( virt(1,1)+virt(2,2)+virt(3,3) )   )
		sys_press = PRESSCON*sys_press !convert to bar
		sum_press = sum_press + sys_press

		Upot = Upott(1)
		tot_energy = (Upot +  uk*MASSCONi)/Nwaters !we want kcal / mol H2O 
		sum_tot_energy = sum_tot_energy + tot_energy

	!pressure / energy calculation : quantum case
	else 
		Upot = iNbeads*sum(Upott)

		call quantum_estimators(RRt, dRRt, sys_press, tot_energy, sys_temp, Upot)
		sum_press = sum_press + sys_press

		sum_tot_energy = sum_tot_energy + tot_energy

	endif

	if (SIMPLE_ENERGY_ESTIMATOR) then
		call simple_quantum_energy_estimator(RRt, dRRt, simple_energy, sys_temp, Upot) 
		sum_simple_energy = sum_simple_energy + simple_energy
	endif 

!print out temperature, pressure, average press & energies
if (mod(t,tp_freq) == 0) then

	tt = tt + 1

	sum_temp      = sum_temp + sys_temp
	sum_energy    = sum_energy + Upot + uk*MASSCONi
	sum_energy2   = sum_energy2 + (Upot + uk*MASSCONi)**2
	sum_RMSenergy = sum_RMSenergy + (Upot + uk*MASSCONi - sum_energy/tt)**2


	write(TPoutStream,'(1f10.4,7f12.2)',advance='no') tr*delt, sys_temp ,sys_press, & 
		sum_temp/tt, sum_press/tr, Upot, tot_energy , sum_tot_energy/tr

  	if (SIMPLE_ENERGY_ESTIMATOR) write(TPoutStream,'(2f12.2)',advance='no') simple_energy, sum_simple_energy/tr

	if (CALC_RADIUS_GYRATION) then
		call calc_radius_of_gyration(RRt,RRc) 
		write(TPoutStream,'(1x,f6.4,1x,f6.4)',advance='no')  radiusO, radiusH
	endif

	!advance to next line
	write(TPoutStream,'(a)') ""



endif 
	tr = tr + 1

!reset averaging after equilbration ends
if  (t .eq. eq_timesteps) then
 	write(TPoutStream,*) "#----end of equilibration---restarting averages----------------------------------"
	!store average temp during equil and final energy after equil
	init_energy = tot_energy 
	init_temp = sum_temp/tt

	!start new averaging of temp & energy
	tt     = 0
	tr     = 1
	sum_temp = 0 
	sum_press = 0 
	sum_tot_energy = 0 
	sum_energy = 0
	sum_energy2 = 0
	sum_RMSenergy = 0
endif 

!write out data during run 
if  (t .gt. eq_timesteps) then
	if (mod(t,t_freq)  == 0 ) then 
		if (coord_out) then
		     call save_XYZ(20, RRc, Upot, read_method, t, delt) 
	  	endif
	  	if (vel_out) then
	   	     call save_XYZ(21, PPc, Upot, read_method, t, delt) 
	   	endif
	   	if (dip_out) then
		     do iw=1,Nwaters
			 !calculate average dipole moment over all beads
			 do j = 1, 3
			 	dip_momI(j,iw) = sum(dip_momIt(j,iw,:))/Nbeads
			 enddo

			 write(22,'(4(1x,f12.4))') dip_momI(:,iw)*DEBYE/CHARGECON , dsqrt(dot_product(dip_momI(:,iw), dip_momI(:, iw)))*DEBYE/CHARGECON
 		     enddo
	   	endif
		if (Edip_out) then
		     do iw=1,Nwaters
		     	!calculate average dipole moment over all beads
 			do j = 1, 3
				dip_momE(j,iw) = sum(dip_momEt(j,iw,:))/Nbeads
			enddo
			write(26,'(3(1x,f12.4))') dip_momE(:,iw)*DEBYE/CHARGECON 
 		     enddo
	   	endif 
 
	endif
	if (mod(t,ti_freq)  == 0 ) then 
		if (OUTPUTIMAGES) then 
			do i = 1, Nbeads
				call save_XYZ(27, RRt(:,:,i), Upot, read_method, t, delt) 
			enddo
		endif 
	endif
	if (mod(t,td_freq)  == 0 ) then 
   		if (TD_out) then
			!calculate average dipole moment over all beads
			do iw=1,Nwaters
				do j = 1, 3
					dip_momI(j,iw) = sum(dip_momIt(j,iw,:))/Nbeads
				enddo
			enddo
    	   		dip_mom(1:3) = sum(dip_momI(1:3, 1:Nwaters), dim=2) *DEBYE/CHARGECON
			write(23,'(3f12.4)') dip_mom
		endif
  	endif
endif

!box size output stuff 
if (BAROSTAT .and. BOXSIZEOUT) then 
        !for accuracy, box size computed at every timestep
        sum_box  = sum_box + box(1)
        sum_box2 = sum_box2 + box(1)**2
        if (mod(t,t_freq) == 0) write(25,*) sum_box/t
endif 

end subroutine write_out


!----------------------------------------------------------------------------------!
!- Quantum estimators for energy & pressure (ref: Tuckerman, "Statistical Mechanics.." 2008 pg 485)
!----------------------------------------------------------------------------------!
subroutine quantum_estimators(RRt, dRRt, qPress, qEnergy, sys_temp, Upot) 
 use consts 
 Implicit none
 double precision, dimension(3,Natoms,Nbeads),intent(in)  :: RRt, dRRt
 double precision, intent(in)      :: sys_temp, Upot
 double precision, intent(out)     :: qPress, qEnergy 
 double precision 		      :: part, qVirial, qVirial2, KE
 integer :: i, j, k 

 !Note on units : it is assumed that dRRt is in (in kcal/(mol*Ang))
 !and that Upot is in kcal/mol and that sys_temp is in Kelvin 

 !The pressure estimator assumes that the potential energy does not have volume dependence

 qVirial = 0 
 qVirial2 = 0 
 do k = 1,Nbeads
	do j = 1, Natoms
		do i = 1, 3
			part = RRc(i,j)*dRRt(i,j,k)
			qVirial2 = qVirial2 - part
			qVirial  = qVirial  + RRt(i,j,k)*dRRt(i,j,k) - part
		enddo
	enddo
 enddo
 qVirial =  iNbeads*.5*qVirial 
 qVirial2 = iNbeads*(1/volume)*qVirial2

 KE = 1.5*Natoms*kb*sys_temp !kinetic energy in kcal/mol

 qEnergy = (KE + qVirial + Upot)/Nwaters !kcal/(mole of mol)
 qPress  = (KE  + qVirial2)/volume

end subroutine quantum_estimators


!----------------------------------------------------------------------------------!
!- Simple 'naive' quantum estimator for the energy (JCP 128, 074506) --------------
!----------------------------------------------------------------------------------!
subroutine simple_quantum_energy_estimator(RRt, dRRt, qEnergy, sys_temp, Upot) 
 use consts 
 Implicit none
 double precision, dimension(3,Natoms,Nbeads),intent(in)  :: RRt, dRRt
 double precision, intent(in)      :: sys_temp, Upot
 double precision, intent(out)     :: qEnergy 
 double precision 		      :: KE, K0, mass
 integer :: i, j, k 

 !Note on units : it is assumed that dRRt is in (in kcal/(mol*Ang))
 !and that Upot is in kcal/mol and that sys_temp is in Kelvin 

 !The pressure estimator assumes that the potential energy does not have volume dependence

 K0 = 0
 do i = 1, 3
	do j = 1, Natoms
		if (mod(j+2,3) .eq. 0) then
			mass = massO 
		else 
			mass = massH
		endif
		do k = 2, Nbeads
			K0 = K0 + mass*( RRt(i,j,k) - RRt(i,j,k-1) )**2
		enddo
	enddo
 enddo

 K0 = .5*K0*omegan**2*MASSCONi

 KE = 1.5*Natoms*kb*sys_temp !kinetic energy in kcal/mol

 qEnergy = (KE*Nbeads + Upot - K0)/Nwaters !kcal/(mole of mol)

end subroutine simple_quantum_energy_estimator


!----------------------------------------------------------------------------------!
!----------Print information about the run ----------------------------------------
!----------------------------------------------------------------------------------!
subroutine print_run

write(TPoutStream,'(a50, f10.3,a3)') "timestep = ", delt*1000, " fs"
if (THERMOSTAT) write(TPoutStream,'(a50, f10.3,a3)') "Nose-Hoover tau = ", tau, " ps"
if (.not. THERMOSTAT) write(TPoutStream,'(a50, a3)') "Nose-Hoover tau = ", "n/a"
if (BEADTHERMOSTAT) write(TPoutStream,'(a50, a )')  " type of bead thermostat = ", bead_thermostat_type
if (CENTROIDTHERMOSTAT) write(TPoutStream,'(a50, a )')  " centroid thermostating = ", "yes"
if (.not. CENTROIDTHERMOSTAT) write(TPoutStream,'(a50, a )')  " centroid thermostating = ", "no"
if (.not. BEADTHERMOSTAT) write(TPoutStream,'(a50, a )')  " type of bead thermostat = ", "none"
if (BEADTHERMOSTAT) write(TPoutStream,'(a50, f10.3,a3)')  " centroid thermostat tau = ", tau_centroid, " ps"
if (.not. BEADTHERMOSTAT) write(TPoutStream,'(a50, a3)') " centroid thermostat tau = ", "n/a"
if (BAROSTAT) write(TPoutStream,'(a50, f10.3,a3)') "Barostat tau = ", tau_p, " ps"
if (.not. BAROSTAT) write(TPoutStream,'(a50, a3)') "Barostat tau = ", "n/a"


write(TPoutStream,*) "#-----------  timing report ----------------------------"
write(TPoutStream,'(a50,i4,a,i4,a)') "Ran with ", Nbeads, " beads on ", Nnodes, " nodes"
write(TPoutStream,'(a50, i5, a7, i3, a9, i3, a8)') "Total elapsed time = ", int(real(seconds)/3600), " hours ",  & 
			int(mod(seconds,3600d0)/60), " minutes ", int(mod(seconds,60d0)), " seconds" 
write(TPoutStream,'(a50, i5, a7, i3, a9, i3, a9, i3, a3)') "Time spent on normal modes = ", int(real(secondsNM)/3600), " hours ", & 
			int(mod(secondsNM,3600d0)/60), " minutes ", int(mod(secondsNM,60d0)), " seconds ", &
			int(1000d0*mod(secondsNM,1d0)), " ms"
write(TPoutStream,'(a50, i5, a7, i3, a9, i3, a9, i3, a3)') "Time spent writing stuff out = ", int(real(secondsIO)/3600)," hours ",& 
			int(mod(secondsIO,3600d0)/60), " minutes ", int(mod(secondsIO,60d0)), " seconds ", int(1000d0*mod(secondsNM,1d0)), " ms"

write(TPoutStream,'(a50, f10.2)') "ps/hour = ", (  (num_timesteps + eq_timesteps)*delt/seconds  )*3600
write(TPoutStream,'(a50, f10.2)') "ps/day = ",  (  (num_timesteps + eq_timesteps)*delt/seconds  )*3600*24



write(TPoutStream,*) "#------------------------------------------------------"
avg_temp =  sum_temp/tt

write(TPoutStream,'(a50, 3f10.2)') "Average temperature during run (K) = ", avg_temp
write(TPoutStream,'(a50, 3f10.2)') "Average pressure during run (bar) = ", sum_press/tr
write(TPoutStream,'(a50, 3f10.2)') "Average total energy during run (kcal/mol) = ", sum_energy/tt
write(TPoutStream,'(a50, 3f10.2)') "estimated energy drift (kcal/mol/ps) = ",(Upot+uk*MASSCONi - init_energy)/(num_timesteps*delt)
write(TPoutStream,'(a50, 3f10.2)') "Temp drift (K/ps) = ", (avg_temp - init_temp)/(num_timesteps*delt)
write(TPoutStream,'(a50, 3f10.2)') "RMS energy fluctuation  (kcal/mol) = ", dsqrt( sum_RMSenergy/tt )

specific_heat = sqrt(   ( sum_energy2/tt - (sum_energy/tt)**2 )/( avg_temp * Kb )  )

write(TPoutStream,'(a50, f10.2)') "Specific heat C_V (only valid in NVT) (cal/g) = ", 1000*specific_heat/18

if (BAROSTAT .and. THERMOSTAT) then
        avg_box2 = sum_box2/(floor(real(tr/t_freq)))
        avg_box  = avg_box /(floor(real(tr/t_freq)))

        isotherm_compress = (avg_box2**3 - avg_box**3)*(10d-7)/(1.38*avg_temp*avg_box)
        write(TPoutStream,'(a50, f10.2)') "Isothermal compressibility (only valid in NPT)=", isotherm_compress
else 
        write(TPoutStream,'(a50, a4)') "Isothermal compressibility (only valid in NPT)=", " n/a"
endif

if (PRINTFINALCONFIGURATION) then 
	open(41, file='out_'//TRIM(fsave)//'_fin_image.xyz', status='unknown')
		call save_configuration(40, RRt, PPt, Upot, t,delt) 
	close(41)
endif

end subroutine print_run



!----------------------------------------------------------------------------------!
!----------Print information about the potential-----------------------------------
!----------------------------------------------------------------------------------!
subroutine print_pot(RR, Upot, dRR, virt, dip_momI, chg, TPoutStream) 
use system_mod
use consts
implicit none
double precision, dimension(3, Natoms), intent(in) :: RR
double precision, intent(in) :: Upot
double precision, dimension(3, Natoms), intent(in) :: dRR
double precision, dimension(3,3), intent(in) :: virt
double precision, dimension(3, Nwaters), intent(in) :: dip_momI
double precision, dimension(3 ) :: dip_mom
double precision, dimension( Natoms ), intent(in) :: chg
integer, intent(in) :: TPoutStream
integer :: iw

dip_mom(1:3) = sum(dip_momI(1:3, 1:Nwaters), dim=2)

write( TPoutStream,'(a50,f14.6)')"Potential Energy (kcal/mol) = ", Upot
write( TPoutStream,'(a50,f14.6)')"Estimated Enthalpy of Vaporization &
(kJ/mol) = ", Upot*4.184 + 1000*8.3144 
write( TPoutStream,'(a50,f14.6)')"monomer Energy = ", Umon
write( TPoutStream,'(a50,f14.6)')"vdw Energy = ", Uvdw
write( TPoutStream,'(a50,f14.6)')"Long range vdw Energy = ", Uvdw_lrc
write( TPoutStream,'(a50,f14.6)')"electrostatic  Energy = ", Uelec
write( TPoutStream,'(a50,f14.6)')"induced Energy = ", Uind
write( TPoutStream,'(a50,3(1x,f12.3))')"Dipole moment [Debye] : ",dip_mom*DEBYE/CHARGECON
write( TPoutStream,'(a/3(10x,f14.5,1x))')"Virial tensor",virt(1:3,1:3)
!write(*,'(/a/)')"DERIVATIVES"
!do iw=1, Nwaters
!   write(*,'(a2,3x,3(f12.6,2x))')"O ",dRR(1:3, 3*iw-2)
!   write(*,'(a2,3x,3(f12.6,2x))')"H ",dRR(1:3, 3*iw-1)
!   write(*,'(a2,3x,3(f12.6,2x))')"H ",dRR(1:3, 3*iw-0)
!enddo
!write(*,'(/,"Dipole moments -X -Y -Z -MAG"/)')
!do iw=1, Nwaters
!   write(*,'(i4,2x,3(f12.6,1x),3x,f12.6)')iw, dip_momI(1:3,iw) / dble(nidols)  *DEBYE/CHARGECON, &
!    dsqrt(dot_product(dip_momI(1:3, iw), dip_momI(1:3, iw))) / dble(nidols)*DEBYE/CHARGECON
!enddo
end subroutine print_pot


!-----------------------------------------------------------------------------------------
!--------------Write out coords-----------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine save_XYZ(iun, RR, Upot, read_method, t, delt) 
use system_mod
use consts
implicit none
double precision, dimension(3, Natoms), intent(in) :: RR
double precision :: Upot,delt
integer ::  i, iO, ih1, ih2, t
integer :: iun, read_method

write(iun,'(i10)') Natoms !, angle
write(iun,'(f12.6,2x,f12.6,3(1x,f12.6))') t*delt, box
if (read_method==0) then
   do i=1, Nwaters
      iO = 3*i-2
      write(iun,'(a2,3(1x,f12.6))')'O ',RR(1:3, iO)
   enddo
   do i=1, Nwaters
      ih1 = 3*i-1
      ih2 = 3*i
      write(iun,'(a2,3(1x,f12.6))')'H ',RR(1:3, ih1)
      write(iun,'(a2,3(1x,f12.6))')'H ',RR(1:3, ih2)
   enddo
else if (read_method==1) then
   do i=1, Nwaters
      iO = 3*i-2
      ih1 = 3*i-1
      ih2 = 3*i
      write(iun,'(a2,3(1x,f12.6))')'O ',RR(1:3, iO)
      write(iun,'(a2,3(1x,f12.6))')'H ',RR(1:3, ih1)
      write(iun,'(a2,3(1x,f12.6))')'H ',RR(1:3, ih2)
   enddo
endif
end subroutine save_XYZ


!-----------------------------------------------------------------------------------------
!--------------Write out configuration --------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine save_configuration(iun, RRt, PPt, Upot, t, delt) 
use system_mod
use consts
implicit none
double precision, dimension(3, Natoms,Nbeads), intent(in) :: RRt, PPt
double precision :: Upot,delt
integer ::  i, j, iO, ih1, ih2, t
integer, intent(in) :: iun 

write(iun,'(i10)') Natoms*Nbeads !, angle
write(iun,'(f12.6,2x,f12.6,3(1x,f12.6))') t*delt,  box  
   do i=1, Nwaters
      iO = 3*i-2
      ih1 = 3*i-1
      ih2 = 3*i
	do j = 1, Nbeads
	      write(iun,'(a2,6(1x,f12.6))')'O ',RRt(1:3, iO,  j), PPt(1:3, iO,  j)*imassO
	enddo
	do j = 1, Nbeads
	 	write(iun,'(a2,6(1x,f12.6))')'H ',RRt(1:3, ih1, j), PPt(1:3, ih1, j)*imassH
	enddo
	do j = 1, Nbeads
	      write(iun,'(a2,6(1x,f12.6))')'H ',RRt(1:3, ih2, j), PPt(1:3, ih2, j)*imassH
	enddo
   enddo
end subroutine save_configuration


!-----------------------------------------------------------------------------------------
!--------------load configuration -------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine load_configuration(iun, RRt, PPt) 
use system_mod
use consts
implicit none
double precision, dimension(3, Natoms,Nbeads), intent(out) :: RRt, PPt
integer ::  i, j, iO, ih1, ih2, t
integer, intent(in) :: iun 

 do i=1, Nwaters
      iO = 3*i-2
      ih1 = 3*i-1
      ih2 = 3*i
	do j = 1, Nbeads
	      read(iun,'(a2,6(1x,f12.6))')  ch2, RRt(1:3, iO,  j), PPt(1:3, iO,  j) 
	      PPt(1:3, iO, j) =  PPt(1:3, iO,  j)*massO
	enddo
	do j = 1, Nbeads
		read(iun,'(a2,6(1x,f12.6))') ch2 ,RRt(1:3, ih1, j), PPt(1:3, ih1, j) 
		PPt(1:3, ih1, j) = PPt(1:3, ih1, j)*massH 
	enddo
	do j = 1, Nbeads
	        read(iun,'(a2,6(1x,f12.6))') ch2 ,RRt(1:3, ih2, j), PPt(1:3, ih2, j) 
		PPt(1:3, ih2, j) =  PPt(1:3, ih2, j)*massH 
	enddo
 enddo
end subroutine load_configuration




end module InputOutput