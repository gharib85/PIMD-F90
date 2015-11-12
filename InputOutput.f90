module InputOutput
 use consts
 use main_stuff
 use lun_management
 use infrared
Implicit none 

 contains
!----------------------------------------------------------------------------------
!---------------- Read input file ------------------------------------------------
!----------------------------------------------------------------------------------
subroutine read_input_file 
 implicit none
 
 call getarg(1, finp)
 narg = command_argument_count()
 if (narg .eq. 0) then
	write(*,*) "ERROR: no input file argument."
	stop
 endif 

 call io_assign(lun) 
 open(lun, file=finp, status='old')

 read(lun,*) 
 read(lun,*)
 read(lun,*)
 read(lun,*)fconfig
 read(lun,*)fsave
 read(lun,*)Nbeads
 read(lun,*)eq_timesteps
 read(lun,*)num_timesteps
 read(lun,*)delt
 read(lun,*) 
 read(lun,*)
 read(lun,*)coord_out
 read(lun,*)vel_out
 read(lun,*)dip_out
 read(lun,*)Edip_out
 read(lun,*)TD_out
 read(lun,*)OUTPUTIMAGES
 read(lun,*)IMAGEDIPOLESOUT
 read(lun,*)BOXSIZEOUT
 read(lun,*)TP_out
 read(lun,*)CALC_RADIUS_GYRATION
 read(lun,*)DIELECTRICOUT
 read(lun,*)CHARGESOUT
 read(lun,*)PRINTFINALCONFIGURATION
 read(lun,*)td_freq
 read(lun,*)tp_freq
 read(lun,*)ti_freq
 read(lun,*)t_freq
 read(lun,*) 
 read(lun,*)
 read(lun,*)pot_model 
 read(lun,*)sys_label, num_SIESTA_nodes
 read(lun,*)Rc, rc1, eps_ewald
 read(lun,*)polar_maxiter, polar_sor, polar_eps, guess_initdip, print_dipiters
 read(lun,*)GENVEL
 read(lun,*)INPCONFIGURATION
 read(lun,*)THERMOSTAT
 read(lun,*)BEADTHERMOSTAT
 read(lun,*)CENTROIDTHERMOSTAT
 read(lun,*)bead_thermostat_type
 read(lun,*)tau
 read(lun,*)tau_centroid
 read(lun,*)global_chain_length
 read(lun,*)bead_chain_length
 read(lun,*)temp
 read(lun,*)BAROSTAT
 read(lun,*)tau_P
 read(lun,*)press 
 read(lun,*)PEQUIL
 read(lun,*) 
 read(lun,*)
 read(lun,*)setNMfreq
 read(lun,*)CONTRACTION
 read(lun,*)intra_timesteps
 read(lun,*)massO
 read(lun,*)massH
 call io_close(lun)  

 !other options: 
 CALCGEOMETRY = .true. !computes averge geometry of h2o molecules and outputs at end
 CALCDIFFUSION = .true. !computes diffusion constant of oxygen atoms
 read_method = 1 !read_method(=0,1) (0 for OOOO....HHHHH and 1 for OHHOHHOHH...)
 SIMPLE_ENERGY_ESTIMATOR = .true. !setting this to true will output the simple energy to temp/press file
 CALCIRSPECTRA = .true. !store dipole moments and calculate IR spectra at end of run
 
end subroutine read_input_file 


!----------------------------------------------------------------------------------
!---------------- Initialize some variables for all nodes ------------------------
!----------------------------------------------------------------------------------
subroutine read_and_initialize_all_nodes
 
!---  read the number of atoms, dimension of box and atomic coordinates 
call io_assign(lunXYZ)

open(lunXYZ,file=fconfig,status='old')

 if (INPCONFIGURATION) then
	read(lunXYZ,*) Natoms 
	read(lunXYZ,*,IOSTAT=ierr) Upot, box(1:3)
	if (ierr .ne. 0) then 
		rewind(lunXYZ)
		read(lunXYZ,*) Natoms 
		read(lunXYZ,*,IOSTAT=ierr) box(1:3)
		if (ierr .ne. 0) then 
			write(*,*) "ERROR: could not read box size from input file. Trying to continue anyway"
		endif 
	endif 

	Natoms = Natoms/Nbeads
 else 
	!usually the box size is in the first line of a raw .xyz
	!but it might be in the second line. Try a few different combos here. 
	read(lunXYZ,*,IOSTAT=ierr) box(1:3)
	read(lunXYZ,*) Natoms 
	if (ierr .ne. 0) then 
		rewind(lunXYZ)
		read(lunXYZ,*) Natoms 
		read(lunXYZ,*,IOSTAT=ierr) box(1:3)
		if (ierr .ne. 0) then 
			rewind(lunXYZ)
			read(lunXYZ,*,IOSTAT=ierr) Natoms, box(1:3)
			if (ierr .ne. 0) then 		
				write(*,*) "ERROR: could not read box size from input file. Trying to continue anyway with box = ", box
			endif 
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
allocate(chg(Natoms))
!allocate(tx_dip(3,4*Nwaters, 4))
allocate(RRc(3, Natoms))

end subroutine read_and_initialize_all_nodes


!----------------------------------------------------------------------------------
!---------- Initialize potential-related variables ---------------------------- 
!----------------------------------------------------------------------------------
subroutine init_potential_all_nodes
 use fsiesta
 Implicit None
 character(len=300) :: sys_command
 character(len=300) :: pipe_name
 
 if (pot_model .eq. 6) then
	pipe_name = trim(sys_label)//".forces"
	inquire(file=trim(pipe_name), exist=EXISTS) 
	if (EXISTS .eqv. .true.) then 
		sys_command = "rm "//pipe_name  
		call system(trim(sys_command))
	endif
	pipe_name = trim(sys_label)//".coords"
	inquire(file=trim(pipe_name), exist=EXISTS) 
	if (EXISTS .eqv. .true.) then 
		sys_command = "rm "//trim(pipe_name) 
		call system(trim(sys_command))
	endif
  !! call siesta_units( "ang", 'kcal/mol' ) ! The combination of ang and kcal/mol doesn't work with Siesta for some reason
	if (num_SIESTA_nodes .eq. 1) then  
		call siesta_launch( trim(sys_label)) !launch serial SIESTA process
    elseif (num_SIESTA_nodes .gt. 1) then  
		call siesta_launch( trim(sys_label), nnodes=num_SIESTA_nodes ) !launch parallel SIESTA process  
	else
		write(*,*) "InputOuput: ERROR: invalid number of SIESTA nodes!!"
	endif
 else
	call init_pot
 endif 

 end subroutine init_potential_all_nodes

!----------------------------------------------------------------------------------
!---------- Error handling  / master node allocations ---------------------------- 
!----------------------------------------------------------------------------------
subroutine master_node_init
	use Langevin 
	use NormalModes
    Implicit None 

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
	write(lunTP_out,*) "InputOutput: WARNING: Bead/centroid thermostating does not make much sense with 1 bead."
	write(lunTP_out,*) "InputOutput: WARNING: The dynamics will be unphysical since every atomic DOF will be thermostated. "
	write(lunTP_out,*) "InputOutput: WARNING: --- The bead thermostat is being turned off ----"
	if (CENTROIDTHERMOSTAT) CENTROIDTHERMOSTAT = .false.
	if (BEADTHERMOSTAT) BEADTHERMOSTAT = .false.
endif

if (BEADTHERMOSTAT .and. .not. (THERMOSTAT)) then
	write(lunTP_out,*) "WARNING: running bead thermostating without a global thermostat is not recommended."
	write(*,*) "You may observe abnormally large temperature fluctuations in the system."
endif

if (CENTROIDTHERMOSTAT.and. .not. (BEADTHERMOSTAT)) then
	write(lunTP_out,*) "WARNING: You are thermostating the centroid but not thermostating the other modes."
	write(*,*) "There is not really any good reason for doing this. Consider a different scheme." 
endif


if ( Rc .gt. minval(box)/2 ) then
	write(lunTP_out,*) 'ERROR: cutoff radius is greater than half the smallest box dimension (', minval(box), ')'
	write(lunTP_out,*) 'suggest changing to', minval(box)/2.0
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

if ( (pot_model .gt. 6) .or. (pot_model .lt. 1) ) then 
	write(*,*) "ERROR: Invalid potential model !"
	stop
endif

if (.not. (CONTRACTION) ) then
	if (.not. (mod(Nbeads,Nnodes) .eq. 0)) then
		write(*,*) "ERROR: the number of beads must be a multiple of the number of nodes."
     	   write(*,'(a,i4,a,i4,a)') "To run on ", Nnodes, " nodes I suggest using ", Nbeads - mod(Nbeads,Nnodes), " beads"
	stop
	endif
else
	if (Nnodes .gt. 2) then 
		write(*,*) "ERROR: When running with ring polymer contraction, a maximum of 2 nodes can be used."
		stop
	endif
endif


	CompFac = ((4.477d-5)*delt)/(3*tau_P) !Barostat var. (contains compressibility of H2O)
	sum_temp = 0 
	sum_press = 0 
	sum_tot_energy = 0 
	sum_simple_energy = 0 
	sum_simple_energy2 = 0 
	sum_simple_press = 0 
	sum_tot_energy2 = 0
	sum_RMSenergy = 0
	sum_box = 0 
	sum_box2 = 0 
	tr = 0
	ttt = 0
	diel_prefac =  debyeSI**2 / (3 * kbSI * vac_permSI * a2m**3) 

	!initialize random number generator
 	CALL RANDOM_SEED(size = m) !get size of seed for the system
 	ALLOCATE(seed(m))
	call system_clock(count=clock) 
	seed = clock + 357 * (/ (i - 1, i = 1, m) /)
 	call random_seed(put = seed)  !put in the seed
 		
	!write(lunTP_out,'(a,i4,a,i4,a)') "Running with ", Nbeads, " beads on ", Nnodes, " nodes"
	
	!Master node allocations
	!only the master node (pid = 0) stores a fully copy of the
	! coords / vel for all beads and the centroid
	allocate(RRt(3, Natoms,Nbeads))
	allocate(PPt(3, Natoms,Nbeads))
	allocate(dRRt(3, Natoms,Nbeads))
	allocate(dip_momIt(3, Nwaters,Nbeads))
	allocate(dip_momEt(3, Nwaters,Nbeads))
	allocate(Upott(Nbeads))
	allocate(Virialt(Nbeads))
	allocate(virialct(Nbeads))
	allocate(PPc(3, Natoms))
    if (CALCIRSPECTRA) allocate(dip_mom_all_times(3, num_timesteps))

	dRRt = 0 


 	if (CONTRACTION) deltfast = delt/intra_timesteps
 	if (CONTRACTION) delt2fast = deltfast/2d0

	if (CONTRACTION) then
		call InitNormalModes(Nbeads, omegan, deltfast, setNMfreq, lunTP_out)
	else
		call InitNormalModes(Nbeads, omegan, delt, setNMfreq, lunTP_out)
	endif

	if (THERMOSTAT)  then
		allocate(vxi_global(global_chain_length))
		vxi_global = 1 !set chain velocities to zero initially
	endif 
	if (BEADTHERMOSTAT)  then
		allocate(vxi_beads(bead_chain_length,natoms,Nbeads,3))
		vxi_beads = 0 !set chain velocities to zero initially
	endif
	if (bead_thermostat_type .eq. 'Langevin') call Init_Langevin_NM(delt2, CENTROIDTHERMOSTAT, tau_centroid, Nbeads, Nbeads*temp)

	!write Temp/Press file header
     call date_and_time(DATE=date,TIME=time)
     write(lunTP_out,'(a)'), " started on  "//date(1:4)//"-"//date(5:6)//"-"//date(7:8)//&
		" at "//time(1:2)//":"//time(3:4)//":"//time(5:10) 

	call print_basic_run_info

end subroutine master_node_init




!----------------------------------------------------------------------------------!
!---------------- Read in coordinate data to RRc ----------------------------------
!----------------------------------------------------------------------------------!
subroutine read_coords

 if (INPCONFIGURATION) then 
	call load_configuration(lunXYZ, RRt, PPt) 
 else 
 	if (read_method .eq. 0) then
        	do i=1, Nwaters
   		 	iO = 3*i-2 
 		 	read(lunXYZ,*)ch2, RRc(1:3, iO)
  		enddo
   	 	do i=1, Nwaters
      			 ih1 = 3*i-1; ih2=3*i
     			 read(lunXYZ,*)ch2, RRc(1:3, ih1)
      			 read(lunXYZ,*)ch2, RRc(1:3, ih2)
  		 enddo
  	else if (read_method==1) then
   		do i=1, Natoms
     			 read(lunXYZ,*)ch2, RRc(1:3, i)
  		enddo
	else 
		write(*,*) "Invalid read method!!"
		stop
	endif 
 endif

 call io_close(lunXYZ)
end subroutine read_coords


!-----------------------------------------------------------------------------------------
!--------------Open write out files -----------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine open_files
 Implicit none 
 logical :: EXISTS
 
 if (TP_out) then 
	call io_assign(lunTP_out)
	open(lunTP_out, file='out_'//TRIM(fsave)//'_TempPress.dat', status='unknown')
	!write(*,*) "Terminal output suppressed to file: ", 'out_'//TRIM(fsave)//'_TempPress.dat'
 else 
	lunTP_out = io_get_stdout()
 endif 

 if (coord_out) then
	call io_assign(luncoord_out)
	inquire(file='out_'//TRIM(fsave)//'_coord.xyz', exist=EXISTS)
  	if (EXISTS) then
		write(lunTP_out,*) "NOTE: coordinate file already exists, backing up previous file."
		call system('mv '//'out_'//TRIM(fsave)//'_coord.xyz'//' '//'out_'//TRIM(fsave)//'_coord_backup.xyz')
   		open(lundip_out, file='out_'//TRIM(fsave)//'_dip.dat', status="old", action="write")
  	else
		open(lundip_out, file='out_'//TRIM(fsave)//'_dip.dat', status="unknown")
	endif
	
	open(luncoord_out, file='out_'//TRIM(fsave)//'_coord.xyz', status='unknown')
 endif
 if (vel_out) then 	
 	call io_assign(lunVEL_OUT)
	open(lunVEL_OUT, file='out_'//TRIM(fsave)//'_mom.dat', status='unknown')
 endif
 if (OUTPUTIMAGES) then
  	call io_assign(lunOUTPUTIMAGES)
	open(lunOUTPUTIMAGES, file='out_'//TRIM(fsave)//'_images_coord.xyz', status='unknown')
 endif
 if  (dip_out) then
   	call io_assign(lundip_out)
	inquire(file='out_'//TRIM(fsave)//'_dip.dat', exist=EXISTS)
  	if (EXISTS) then
		write(lunTP_out,*) "NOTE: Dipoles file already exists, appending to end of file"
   		open(lundip_out, file='out_'//TRIM(fsave)//'_dip.dat', status="old", position="append", action="write")
  	else
    		open(lundip_out, file='out_'//TRIM(fsave)//'_dip.dat', status="unknown")
	endif
 endif
 if (TD_out) then 
	call io_assign(lunTD_out)
	inquire(file='out_'//TRIM(fsave)//'_tot_dip.dat', exist=EXISTS)
  	if (EXISTS) then
		write(lunTP_out,*) "NOTE: Total dipole file already exists, appending to end of file"
   		open(lunTD_out, file='out_'//TRIM(fsave)//'_tot_dip.dat', status="old", position="append", action="write")
  	else
    		open(lunTD_out, file='out_'//TRIM(fsave)//'_tot_dip.dat', status="unknown")
	endif
 endif
 if  (Edip_out) then
    	call io_assign(lunEdip_out)
	open(lunEdip_out, file='out_'//TRIM(fsave)//'_Edip.dat', status='unknown')
 endif
 if (BOXSIZEOUT) then 
	call io_assign(lunBOXSIZEOUT)
	open(lunBOXSIZEOUT, file='out_'//TRIM(fsave)//'_box.dat', status='unknown')
 endif
 if (CHARGESOUT) then
	call io_assign(lunCHARGESOUT)
	open(lunCHARGESOUT, file='out_'//TRIM(fsave)//'_chgs.dat', status='unknown')
 endif
 if (IMAGEDIPOLESOUT) then
	call io_assign(lunIMAGEDIPOLESOUT)
	open(lunIMAGEDIPOLESOUT, file='out_'//TRIM(fsave)//'_images_dip.dat', status='unknown')
 endif

end subroutine open_files


!----------------------------------------------------------------------------------
!-------------- Calculate thermodynamic info and write out to file(s) ------------
!----------------------------------------------------------------------------------
subroutine write_out 
 use geometry_calculator
 use diffusion_calculator
 use dans_timer
 use estimators
 implicit none

 !for accuracy, pressure is computed at every timestep, since P fluctuations are large
 !total energy and temperature is also calculated every timestep
 !in some instances, slight speedups were sacrificed for code readability 

 !reset averaging after equilbration ends
 if (t .eq. eq_timesteps + 1) then
 	write(lunTP_out,*) "#----end of equilibration---restarting averages----------------------------------"
	!store average temp during equil and final energy after equil
	init_energy = tot_energy 
	init_temp = sum_temp/tr

	!start new averaging  
	tr     = 0
	ttt    = 0
	sum_temp = 0 
	sum_press = 0 
	sum_dip = 0 
	sum_dip2 = 0 
	sum_tot_energy = 0 
	sum_simple_energy = 0 
	sum_simple_energy2 = 0 
	sum_simple_press = 0 
	sum_tot_energy2 = 0
	sum_RMSenergy = 0
	sum_radiusH = 0
	sum_radiusO = 0 
	if (CALCGEOMETRY) call write_out_geometry(lunTP_out,Nbeads)
	if (CALCGEOMETRY) call reset_geometry
 endif 

  !write columns header
 if ((t .eq. 1) .or. (t .eq. eq_timesteps + 1)) then 
	write(lunTP_out,'(a)',advance='no') " time (ps) "
	!write(lunTP_out,'(a)',advance='no') "  temp (K) "
	!write(lunTP_out,'(a)',advance='no') "  press.(bar)  "
	write(lunTP_out,'(a)',advance='no') " avg temp " 
	write(lunTP_out,'(a)',advance='no') "avgP(vir) "
	if (SIMPLE_ENERGY_ESTIMATOR) write(lunTP_out,'(a)',advance='no') "avgP(simp)"

	!write(lunTP_out,'(a)',advance='no') "  Pot E  "
	!write(lunTP_out,'(a)',advance='no') "  Tot E  "
	write(lunTP_out,'(a)',advance='no') " avgTotE(vir) " 
										
	!if (SIMPLE_ENERGY_ESTIMATOR) write(lunTP_out,'(a)',advance='no')  " Tot E (simple) " 
	if (SIMPLE_ENERGY_ESTIMATOR) write(lunTP_out,'(a)',advance='no')   " avgTotE(simp)"
	if (CALC_RADIUS_GYRATION)    write(lunTP_out,'(a,a)',advance='no') " r_O  ", "r_H "
	if (DIELECTRICOUT)           write(lunTP_out,'(a)',advance='no') "  eps(0)  "
	!write(lunTP_out,'(a)',advance=no") " density kg/m^3 "
	write(lunTP_out,'(a)',advance='no') "[ energies in kcal/mol ]"
	write(lunTP_out,'(a)',advance='yes') "" 
 endif
 
 
 tr = tr + 1

 sys_temp = TEMPFACTOR*uk/(Natoms*Nbeads*Nbeads)

! call calc_uk_centroid
! write(lunTP_out,*) "centroid temp =", TEMPFACTOR*uk/(Natoms)
 !uk = 0 
 !do j = 1, Nbeads
!	do i = 1,Nwaters
!		uk = uk + imassO*sum( PPt(:,3*i-2,j)**2 ) 
!		uk = uk + imassH*sum( PPt(:,3*i-1,j)**2 ) 
!		uk = uk + imassH*sum( PPt(:,3*i-0,j)**2 ) 
!	enddo
 !enddo	
 !uk = .5d0*uk 
! write(lunTP_out,*) "naive bead temp =", TEMPFACTOR*uk/(Natoms)

 !- pressure / total energy calculation : old classical case -
 !sys_press =  PRESSCON*(1/(3*volume))*( 2*uk -	 MASSCON*( virt(1,1)+virt(2,2)+virt(3,3) )  )

 call quantum_virial_estimators(RRt, virial, virialc, tot_energy, sys_press, sys_temp, Upot)
 call simple_quantum_estimators(RRt, virial, simple_energy, simple_sys_press, sys_temp, Upot) 

 sum_simple_energy = sum_simple_energy + simple_energy
 sum_simple_energy2 = sum_simple_energy2 + simple_energy**2
 sum_simple_press  = sum_simple_press + simple_sys_press
 sum_press         = sum_press + sys_press
 sum_tot_energy    = sum_tot_energy + tot_energy
 sum_temp          = sum_temp + sys_temp
 sum_tot_energy2   = sum_tot_energy2 + tot_energy**2
 sum_RMSenergy     = sum_RMSenergy + (tot_energy - sum_tot_energy/tr)**2

 !!debug options
 !write(*,*) "Upot   " , Upot
 !write(*,*) "virial " , virial
 !write(*,*) "virialc" , virialc
 !write(*,*) "simple P" , simple_sys_press
 !write(*,*) "virial P" , sys_press
 !write(*,*) "simple E" , simple_energy
 !write(*,*) "virial E" , tot_energy

 !caculate dipole moments only if necessary 
 !if ( (DIELECTRICOUT .and. (mod(t,10).eq.0) )  .or. ( (t .gt. eq_timesteps) .and. ( (TD_out) .or. ( dip_out.and.(mod(t,t_freq).eq.0) ) ) )  then 
 
 !first, convert dipoles in all images into Debye
 dip_momIt = dip_momIt*DEBYE/CHARGECON   
 dip_momEt = dip_momEt*DEBYE/CHARGECON   

 !calculate dipole moment by averaging over all beads
 do iw=1,Nwaters
	do j = 1, 3
		dip_momI(j,iw) = sum(dip_momIt(j,iw,:))/Nbeads
	enddo
 enddo
 
 !caculate total dipole moment (in Debye)
 dip_mom(:) = sum(dip_momI(:,:), dim=2)
 
 !update quantities for dielectric constant 
 !it really isn't necessary to do this every timestep, so we do it every 10 steps
 if (DIELECTRICOUT .and. ( mod(t,10) .eq. 0 )  ) then 
	sum_dip  = sum_dip  + dip_mom
	sum_dip2 = sum_dip2 + sum(dip_mom**2)
	ttt = ttt + 1
 endif
 
 if (CALCGEOMETRY) then 
	call start_timer("calc_geometry")
	call calc_geometry(RRc, RRt, Nbeads)
	call stop_timer("calc_geometry")
 endif 
 
 if (CALC_RADIUS_GYRATION) call calc_radius_of_gyration(RRt,RRc) 

 !-------------------------------------------------------------
 !print out temperature, pressure, average press, energies & dielectric constant
 !-------------------------------------------------------------
  if (mod(t,tp_freq) == 0) then
	write(lunTP_out,'(1f10.4)',advance='no') tr*delt 
	!write(lunTP_out,'(1f10.2)',advance='no') sys_temp
	write(lunTP_out,'(1f10.2)',advance='no') sum_temp/tr
	!write(lunTP_out,'(1f10.2)',advance='no') sys_press
	write(lunTP_out,'(1f11.2)',advance='no') sum_press/tr
	if (SIMPLE_ENERGY_ESTIMATOR) then 
		!write(lunTP_out,'(f10.2)',advance='no') simple_sys_press 
		write(lunTP_out,'(1f11.2)',advance='no') sum_simple_press/tr
	endif
	
	!write(lunTP_out,'(2f10.2)',advance='no') Upot, tot_energy
	write(lunTP_out,'(1f10.2)',advance='no') sum_tot_energy/tr
  	if (SIMPLE_ENERGY_ESTIMATOR) then 
	 !write(lunTP_out,'(f10.2)',advance='no') simple_energy
	 write(lunTP_out,'(f10.2)',advance='no') sum_simple_energy/tr
	endif

	if (CALC_RADIUS_GYRATION) then
		!write(lunTP_out,'(1x,f6.4,1x,f6.4)',advance='no')  radiusO, radiusH
		write(lunTP_out,'(1x,f6.4,1x,f6.4)',advance='no')  sum_radiusO/tr, sum_radiusH/tr
	endif

	!calculate dielectric constant using current volume and average temperature of the run
	if (DIELECTRICOUT) then 
		dielectric_constant = diel_prefac*(  sum_dip2/ttt - sum( (sum_dip/ttt)**2 )  )/volume/(sum_temp/tr)
		write(lunTP_out,'(1x,f6.2)',advance='no') dielectric_constant
		!if (mod(t,num_timesteps/1000) .eq. 0) then
		!	dielectric_running(dielectric_index) = dielectric_constant
		!	dielectric_index = dielectric_index + 1
		!endif 
	endif 

	!feature to output the current density (for debugging the barostat) 
	!write(lunTP_out,'(1x,f10.6)',advance='no') Nwaters*(massO+2*massH)*amu2grams/(box(1)*box(2)*box(3)*(a2m*100)**3)

	!advance to next line
	write(lunTP_out,'(a)') ""
#ifdef FC_HAVE_FLUSH
	call flush(lunTP_out) !flush I/O buffer	
#endif
 endif 

 !-------------------------------------------------------------
 !write out / store data during run phase 
 !-------------------------------------------------------------
 if (t .gt. eq_timesteps) then
 
    if (CALCIRSPECTRA) dip_mom_all_times(1:3, tr) = dip_mom(:)

    if (CALCDIFFUSION) then
		call start_timer("calc_diffusion")
		call calc_diff_RMSD(RRc, num_timesteps) 
		call stop_timer("calc_diffusion")
	endif
    
	if (mod(t,t_freq)  == 0 ) then 
		!coordinate output
		if (coord_out) then
		     call save_XYZ(luncoord_out, RRc, Upot, read_method, t, delt) 
#ifdef FC_HAVE_FLUSH
		     call flush(luncoord_out) 
#endif
		     endif
		!velocity output
	  	if (vel_out) then
	   	     call save_XYZ(lunVEL_OUT, PPc, Upot, read_method, t, delt) 
	   	endif
		!dipoles output
	   	if (dip_out) then
		     do iw=1,Nwaters
			 write(lundip_out,'(4(1x,f12.4))') dip_momI(:,iw) , & 
				 dsqrt(dot_product(dip_momI(:,iw), dip_momI(:, iw))) 
 		     enddo
#ifdef FC_HAVE_FLUSH
 		     call flush(lundip_out)
#endif
	   	endif
		!electronic dipoles output
		if (Edip_out) then
		     do iw=1,Nwaters
 			do j = 1, 3
				dip_momE(j,iw) = sum(dip_momEt(j,iw,:))/Nbeads
			enddo
			 write(lunEdip_out,'(4(1x,f12.4))') dip_momE(:,iw) , & 
				 dsqrt(dot_product(dip_momE(:,iw), dip_momE(:, iw))) 
 		     enddo
#ifdef FC_HAVE_FLUSH
			call flush(lunEdip_out)
#endif
			endif 
		!charges out
                if (CHARGESOUT) then
			do iw = 1, 3*Nwaters
				write(lunCHARGESOUT,*) chg(iw)*0.20819434d0*DEBYE/CHARGECON 
 		        enddo
		endif
	endif
	!images output
	if (mod(t,ti_freq)  == 0) then
		if (OUTPUTIMAGES) then  
			do i = 1, Nbeads
				call save_XYZ(lunOUTPUTIMAGES, RRt(:,:,i), Upot, read_method, t, delt) 
			enddo
#ifdef FC_HAVE_FLUSH
			flush(lunOUTPUTIMAGES)
#endif
			endif 
		if (IMAGEDIPOLESOUT) then 
			do i = 1, Nbeads
				do iw = 1,Nwaters
			 		write(lunIMAGEDIPOLESOUT,'(4(1x,f12.4))') dip_momIt(:,iw,i), & 
				 		dsqrt(dot_product(dip_momIt(:,iw,i), dip_momIt(:,iw,i))) 
				enddo
			enddo
		endif
	endif
	!total dipole moment output 
	if (mod(t,td_freq)  == 0 .and. TD_out ) then 
		write(lunTD_out,'(3f12.4)') dip_mom
#ifdef FC_HAVE_FLUSH
		flush(lunTD_out)
#endif
  	endif
 endif !t .gt. eq_timesteps

!box size output stuff 
if (BAROSTAT) then 
	!for accuracy, box size computed at every timestep
    sum_box  = sum_box + box
    sum_box2 = sum_box2 + box**2
    if (BOXSIZEOUT .and. (mod(t,t_freq) .eq. 0) ) write(lunBOXSIZEOUT,*) sum_box/t
endif 

end subroutine write_out

!----------------------------------------------------------------------------------
!----------Print information about the run ---------------------------------------
!----------------------------------------------------------------------------------
subroutine print_run
  use dans_timer
  use geometry_calculator
  use diffusion_calculator
 implicit none

 !write Temp/Press file header
 call date_and_time(DATE=date,TIME=time)
 write(lunTP_out,'(a)'), " stopped on  "//date(1:4)//"-"//date(5:6)//"-"//date(7:8)//&
           " at "//time(1:2)//":"//time(3:4)//":"//time(5:10) 
 call print_basic_run_info
 call print_timing_report(lunTP_out)

 call get_time("Total time", seconds) 
 write(lunTP_out,'(a50, f10.2)') "ps/hour = ", (  (num_timesteps + eq_timesteps)*delt/seconds  )*3600
 write(lunTP_out,'(a50, f10.2)') "ps/day = ",  (  (num_timesteps + eq_timesteps)*delt/seconds  )*3600*24
 
 write(lunTP_out,*) "#------- thermodynamics: -------------------------------"
 avg_temp =  sum_temp/tr

 write(lunTP_out,'(a50, 3f10.2)') "Average temperature during run (K) = ", avg_temp/Nbeads
 write(lunTP_out,'(a50, 3f10.2)') "Average pressure during run (bar) = ", sum_press/tr
 write(lunTP_out,'(a50, 3f10.2)') "Average total energy during run (kcal/mole) = ", sum_tot_energy/tr
 write(lunTP_out,'(a50, 3f10.2)') "Estimated energy drift (kcal/mole/ps) = ",(tot_energy - init_energy)/(num_timesteps*delt)
 write(lunTP_out,'(a50, 3f10.2)') "Temp drift (K/ps) = ", (avg_temp - init_temp)/(num_timesteps*delt)
 write(lunTP_out,'(a50, 3f10.2)') "RMS energy fluctuation  (kcal/mol) = ", dsqrt( sum_tot_energy2/tr - (sum_tot_energy/tr)**2 )
 
 specific_heat = dsqrt(  sum_tot_energy2/tr - (sum_tot_energy/tr)**2  ) /( kb*avg_temp )
 write(lunTP_out,'(a50, f10.2)') "Specific heat C_V (only valid in NVT) (cal/g) = ", specific_heat/(1000*(massO+2*massH))
 
 if (Nbeads .gt. 1) then 
	specific_heat = dsqrt(  sum_simple_energy2/tr - (sum_simple_energy/tr)**2  ) /( kb*avg_temp )
	write(lunTP_out,'(a50, f10.2)') "Quantum specific heat C_V (only valid in NVT) (cal/g) = ", specific_heat/(1000*(massO+2*massH))
 endif

 if (BAROSTAT) then
    avg_box2 = sum_box2/t
    avg_box  = sum_box/t 

	write(lunTP_out,'(a50, 3f10.6)') "average box size (over entire run) (Ang) = ", avg_box
	write(lunTP_out,'(a50, f10.2)') "average density (g/cm^3) = ", &
		Nwaters*(massO+2*massH)*amu2grams/(avg_box(1)*avg_box(2)*avg_box(3)*(a2m*100)**3)

	isotherm_compress = &
		(avg_box2(1)**3 - (avg_box(1)*avg_box(2)*avg_box(3))**2 )*(10d-7)/(1.38d0*avg_temp*avg_box(1)*avg_box(2)*avg_box(3))
    
    write(lunTP_out,'(a50, f10.2)') "Isothermal compressibility =", isotherm_compress
    write(lunTP_out,'(a)') "Note : isothermal compressibility only valid in NPT, assumes cubic box, not validated" 
 else 
	write(lunTP_out,'(a50, f10.2)') "density (fixed) (g/cm^3) = ", Nwaters*(massO+2*massH)*amu2grams/(volume*(a2m*100)**3)
 endif
 
 if (CALCGEOMETRY)  call write_out_geometry(lunTP_out,Nbeads)
 if (CALCDIFFUSION) call write_out_diffusion(lunTP_out, delt, fsave)
 
 if (DIELECTRICOUT) then 
    write(lunTP_out,'(a50 )')         "#---------- dielectric constant data  ---------------"
	write(lunTP_out,'(a50, f10.2)') " dielectric constant ", dielectric_constant
	if (num_timesteps .gt. 1000) then 
		dielectric_error = sum( (dielectric_running(500:1000) - dielectric_constant)**2 ) /500
	  	write(lunTP_out,'(a50, f16.2)') "estimated error = +/-", dielectric_error
	endif	
	write(lunTP_out,'(a50, f16.2)') " sum M^2 (Debye^2) ", sum_dip2 
	write(lunTP_out,'(a50, f16.2)') " sum M (Debye^2) ", sum_dip
	write(lunTP_out,'(a50, f16.2)') " average <M^2> (Debye^2) ", sum_dip2/ttt
	write(lunTP_out,'(a50, f16.2)') " average <M>^2 (Debye^2) ", sum(sum_dip**2)/ttt
	write(lunTP_out,'(a50, i5)') " points used to compute dielectric constant: ", ttt
 endif

 if (CALCIRSPECTRA) call calc_infrared_spectrum(dip_mom_all_times,box,delt,fsave,temp)
 
 if (PRINTFINALCONFIGURATION) then 
	call io_assign(lun)
	open(lun, file='out_'//TRIM(fsave)//'_fin_image.xyz', status='unknown')
	call save_configuration(lun, RRt, PPt, Upot, t,delt) 
	close(lun)
 endif

 if (coord_out) then
	call io_close(luncoord_out)
 endif
 if (vel_out) then 	
	call io_close(lunVEL_OUT)
 endif
 if (OUTPUTIMAGES) then
	call io_close(lunOUTPUTIMAGES)
 endif
 if  (dip_out) then
	call io_close(lundip_out)
 endif
 if  (Edip_out) then
	call io_close(lunEdip_out)
 endif
 if (TD_out) then 
	call io_close(lunTD_out)
 endif
 if (BOXSIZEOUT) then 
	call io_close(lunBOXSIZEOUT)
 endif
 if (TP_out) then 
	call io_close(lunTP_out)
 endif
 if (CHARGESOUT) then 
	call io_close(lunCHARGESOUT)
 endif
end subroutine print_run

!----------------------------------------------------------------------------------
!----------Print basic information about the run ---------------------------------
!----------------------------------------------------------------------------------
subroutine print_basic_run_info
 if (pot_model .eq. 2) write(lunTP_out,'(a50,a)') "Model = ", "TTM2F"
 if (pot_model .eq. 3) write(lunTP_out,'(a50,a)') "Model = ", "TTM3F"
 if (pot_model .eq. 4) write(lunTP_out,'(a50,a)') "Model = ", "qSPCfw"
 if (pot_model .eq. 5) write(lunTP_out,'(a50,a)') "Model = ", "SPCf"
 if (pot_model .eq. 6) write(lunTP_out,'(a50,a,a,a,i5)') "Model = ", "SIESTA  sys_label = ", &
									trim(sys_label), "  num_SIESTA_nodes = ", num_SIESTA_nodes
 write(lunTP_out,'(a50,i4,a,i4,a)') "Running with ", Nbeads, " beads on ", Nnodes, " nodes"
 write(lunTP_out,'(a50, i6)') "Num Molecules = ", Nwaters
 write(lunTP_out,'(a50, f10.3,a3)') "timestep = ", delt*1000, " fs"
 write(lunTP_out,'(a50, f8.4,a21,f8.4)') "mass of hydrogen = ", massH, "  mass of oxygen = ", massO
 if (CONTRACTION) write(lunTP_out,'(a50,a)') "ring polymer contraction to centroid = ", "yes"
 if (.not. CONTRACTION) write(lunTP_out,'(a50,a)') "ring polymer contraction to centroid = ", "no"
 if (THERMOSTAT) write(lunTP_out,'(a50, a )')  " type of global thermostat = ", "Nose-Hoover"
 if (.not. THERMOSTAT) write(lunTP_out,'(a50, a )')  " type of global thermostat = ", "none"
 if (.not. THERMOSTAT) write(lunTP_out,'(a50, a3)') "global thermostat tau = ", "n/a"
 if (THERMOSTAT) write(lunTP_out,'(a50, f10.3,a3)') "global thermostat tau = ", tau, " ps"
 if (BEADTHERMOSTAT) write(lunTP_out,'(a50, a )')  " type of bead thermostat = ", bead_thermostat_type
 if (CENTROIDTHERMOSTAT) write(lunTP_out,'(a50, a )')  " centroid thermostating = ", "yes"
 if (.not. CENTROIDTHERMOSTAT) write(lunTP_out,'(a50, a )')  " centroid thermostating = ", "no"
 if (.not. BEADTHERMOSTAT) write(lunTP_out,'(a50, a )')  " type of bead thermostat = ", "none"
 if (BEADTHERMOSTAT) write(lunTP_out,'(a50, f10.3,a3)')  " centroid thermostat tau = ", tau_centroid, " ps"
 if (.not. BEADTHERMOSTAT) write(lunTP_out,'(a50, a3)') " centroid thermostat tau = ", "n/a"
 if (BAROSTAT) write(lunTP_out,'(a50, f10.3,a3)') "Barostat tau = ", tau_p, " ps"
 if (.not. BAROSTAT) write(lunTP_out,'(a50, a3)') "Barostat tau = ", "n/a"
end subroutine print_basic_run_info

!----------------------------------------------------------------------------------
!----------Print information about the potential----------------------------------
!----------------------------------------------------------------------------------
subroutine print_pot(RR, Upot, dRR, virt, dip_momI, chg, lunTP_out) 
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
integer, intent(in) :: lunTP_out
integer :: iw

dip_mom(1:3) = sum(dip_momI(1:3, 1:Nwaters), dim=2)

write( lunTP_out,'(a50,f14.6)')"Potential Energy (kcal/mol) = ", Upot
write( lunTP_out,'(a50,f14.6)')"Estimated Enthalpy of Vaporization &
(kJ/mol) = ", Upot*4.184 + 1000*8.3144 
write( lunTP_out,'(a50,f14.6)')"monomer Energy = ", Umon
write( lunTP_out,'(a50,f14.6)')"vdw Energy = ", Uvdw
write( lunTP_out,'(a50,f14.6)')"Long range vdw Energy = ", Uvdw_lrc
write( lunTP_out,'(a50,f14.6)')"electrostatic  Energy = ", Uelec
write( lunTP_out,'(a50,f14.6)')"induced Energy = ", Uind
write( lunTP_out,'(a50,3(1x,f12.3))')"Dipole moment [Debye] : ",dip_mom*DEBYE/CHARGECON
write( lunTP_out,'(a/3(10x,f14.5,1x))')"Virial tensor",virt(1:3,1:3)
!write(*,'(/a/)')"DERIVATIVES"
!do iw=1, Nwaters
!   write(*,'(a2,3x,3(f12.6,2x))')"O ",dRR(1:3, 3*iw-2)
!   write(*,'(a2,3x,3(f12.6,2x))')"H ",dRR(1:3, 3*iw-1)
!   write(*,'(a2,3x,3(f12.6,2x))')"H ",dRR(1:3, 3*iw-0)
!enddo
end subroutine print_pot


!-----------------------------------------------------------------------------------------
!--------------Write out coords----------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine save_XYZ(iun, RR, Upot, read_method, t, delt) 
use system_mod
use consts
implicit none
double precision, dimension(3, Natoms), intent(in) :: RR
double precision ::  delt, Upot 
integer ::  i, iO, ih1, ih2, t
integer :: iun, read_method

write(iun,'(i10)') Natoms !, angle
write(iun,*) ""
!write(iun,'(f12.6,2x,f12.6,3(1x,f12.6))') t*delt, box
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
double precision :: delt, Upot
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


!-----------------------------------------------------------------------------------------
!--------------Shutdown program ---------------------------------------------------------
!-----------------------------------------------------------------------------------------
subroutine shutdown 
 use system_mod
 use fsiesta

 if (pid .eq. 0)  then
	call print_run
 endif

 if (pot_model == 6) call siesta_quit( trim(sys_label) )
 
 call MPI_Barrier(MPI_COMM_WORLD, ierr)
 call MPI_Finalize(ierr)

end subroutine shutdown



end module InputOutput
