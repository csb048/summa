! SUMMA - Structure for Unifying Multiple Modeling Alternatives
! Copyright (C) 2014-2020 NCAR/RAL; University of Saskatchewan; University of Washington
!
! This file is part of SUMMA
!
! For more information see: http://www.ral.ucar.edu/projects/summa
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

module summaSolve_module

! data types
USE nrtype

! constants
USE multiconst,only:Tfreeze         ! freezing point of pure water (K)
USE multiconst,only:iden_water      ! intrinsic density of liquid water (kg m-3)

! access the global print flag
USE globalData,only:globalPrintFlag

! access missing values
USE globalData,only:integerMissing  ! missing integer
USE globalData,only:realMissing     ! missing double precision number
USE globalData,only:quadMissing     ! missing quadruple precision number

! access named variables to describe the form and structure of the matrices used in the numerical solver
USE globalData,only: ku             ! number of super-diagonal bands
USE globalData,only: kl             ! number of sub-diagonal bands
USE globalData,only: nBands         ! length of the leading dimension of the band diagonal matrix
USE globalData,only: ixFullMatrix   ! named variable for the full Jacobian matrix
USE globalData,only: ixBandMatrix   ! named variable for the band diagonal matrix
USE globalData,only: iJac1          ! first layer of the Jacobian to print
USE globalData,only: iJac2          ! last layer of the Jacobian to print

! named variables to describe the state variable type
USE globalData,only:iname_nrgCanair ! named variable defining the energy of the canopy air space
USE globalData,only:iname_nrgCanopy ! named variable defining the energy of the vegetation canopy
USE globalData,only:iname_watCanopy ! named variable defining the mass of water on the vegetation canopy
USE globalData,only:iname_nrgLayer  ! named variable defining the energy state variable for snow+soil layers
USE globalData,only:iname_watLayer  ! named variable defining the total water state variable for snow+soil layers
USE globalData,only:iname_liqLayer  ! named variable defining the liquid  water state variable for snow+soil layers
USE globalData,only:iname_matLayer  ! named variable defining the matric head state variable for soil layers
USE globalData,only:iname_lmpLayer  ! named variable defining the liquid matric potential state variable for soil layers

! indices of elements of data structure
USE var_lookup,only:iLookFLUX       ! named variables for structure elements
USE var_lookup,only:iLookPROG       ! named variables for structure elements
USE var_lookup,only:iLookPARAM      ! named variables for structure elements
USE var_lookup,only:iLookINDEX      ! named variables for structure elements
USE var_lookup,only:iLookDECISIONS  ! named variables for elements of the decision structure

! provide access to the derived types to define the data structures
USE data_types,only:&
                    var_i,        & ! data vector (i4b)
                    var_d,        & ! data vector (dp)
                    var_ilength,  & ! data vector with variable length dimension (i4b)
                    var_dlength,  & ! data vector with variable length dimension (dp)
                    model_options   ! defines the model decisions

! look-up values for the choice of groundwater parameterization
USE mDecisions_module,only:       &
                    qbaseTopmodel,& ! TOPMODEL-ish baseflow parameterization
                    bigBucket,    & ! a big bucket (lumped aquifer model)
                    noExplicit      ! no explicit groundwater parameterization

implicit none
private
public::summaSolve
contains

 ! *********************************************************************************************************
 ! public subroutine summaSolve: calculate the iteration increment, evaluate the new state, and refine if necessary
 ! *********************************************************************************************************
 subroutine summaSolve(&
                       ! input: model control
                       dt,                      & ! intent(in):    length of the time step (seconds)
                       iter,                    & ! intent(in):    iteration index
                       nSnow,                   & ! intent(in):    number of snow layers
                       nSoil,                   & ! intent(in):    number of soil layers
                       nLayers,                 & ! intent(in):    total number of layers
                       nLeadDim,                & ! intent(in):    length of the leading dimension of the Jacobian matrix (either nBands or nState)
                       nState,                  & ! intent(in):    total number of state variables
                       ixMatrix,                & ! intent(in):    type of matrix (full or band diagonal)
                       firstSubStep,            & ! intent(in):    flag to indicate if we are processing the first sub-step
                       firstFluxCall,           & ! intent(inout): flag to indicate if we are processing the first flux call
                       computeVegFlux,          & ! intent(in):    flag to indicate if we need to compute fluxes over vegetation
                       scalarSolution,          & ! intent(in):    flag to indicate the scalar solution
                       ! input: state vectors
                       stateVecTrial,           & ! intent(in):    trial state vector
                       xMin,xMax,               & ! intent(inout): brackets of the root
                       fScale,                  & ! intent(in):    function scaling vector
                       xScale,                  & ! intent(in):    "variable" scaling vector, i.e., for state variables
                       rVec,                    & ! intent(in):    residual vector
                       sMul,                    & ! intent(in):    state vector multiplier (used in the residual calculations)
                       dMat,                    & ! intent(inout): diagonal matrix (excludes flux derivatives)
                       fOld,                    & ! intent(in):    old function evaluation
                       ! input: data structures
                       model_decisions,         & ! intent(in):    model decisions
                       type_data,               & ! intent(in):    type of vegetation and soil
                       attr_data,               & ! intent(in):    spatial attributes
                       mpar_data,               & ! intent(in):    model parameters
                       forc_data,               & ! intent(in):    model forcing data
                       bvar_data,               & ! intent(in):    average model variables for the entire basin
                       prog_data,               & ! intent(in):    model prognostic variables for a local HRU
                       ! input-output: data structures
                       indx_data,               & ! intent(inout): index data
                       diag_data,               & ! intent(inout): model diagnostic variables for a local HRU
                       flux_data,               & ! intent(inout): model fluxes for a local HRU
                       deriv_data,              & ! intent(inout): derivatives in model fluxes w.r.t. relevant state variables
                       ! input-output: baseflow
                       ixSaturation,            & ! intent(inout): index of the lowest saturated layer (NOTE: only computed on the first iteration)
                       dBaseflow_dMatric,       & ! intent(inout): derivative in baseflow w.r.t. matric head (s-1)
                       ! output
                       stateVecNew,             & ! intent(out):   new state vector
                       fluxVecNew,              & ! intent(out):   new flux vector
                       resSinkNew,              & ! intent(out):   additional (sink) terms on the RHS of the state equation
                       resVecNew,               & ! intent(out):   new residual vector
                       fNew,                    & ! intent(out):   new function evaluation
                       converged,               & ! intent(out):   convergence flag
                       err,message)               ! intent(out):   error control
 USE computJacob_module, only: computJacob
 USE matrixOper_module,  only: lapackSolv
 USE matrixOper_module,  only: scaleMatrices
 implicit none
 ! --------------------------------------------------------------------------------------------------------------------------------
 ! input: model control
 real(rkind),intent(in)             :: dt                       ! length of the time step (seconds)
 integer(i4b),intent(in)         :: iter                     ! interation index
 integer(i4b),intent(in)         :: nSnow                    ! number of snow layers
 integer(i4b),intent(in)         :: nSoil                    ! number of soil layers
 integer(i4b),intent(in)         :: nLayers                  ! total number of layers
 integer(i4b),intent(in)         :: nLeadDim                 ! length of the leading dimension of the Jacobian matrix (nBands or nState)
 integer(i4b),intent(in)         :: nState                   ! total number of state variables
 integer(i4b),intent(in)         :: ixMatrix                 ! type of matrix (full or band diagonal)
 logical(lgt),intent(in)         :: firstSubStep             ! flag to indicate if we are processing the first sub-step
 logical(lgt),intent(inout)      :: firstFluxCall            ! flag to indicate if we are processing the first flux call
 logical(lgt),intent(in)         :: computeVegFlux           ! flag to indicate if computing fluxes over vegetation
 logical(lgt),intent(in)         :: scalarSolution           ! flag to denote if implementing the scalar solution
 ! input: state vectors
 real(rkind),intent(in)             :: stateVecTrial(:)         ! trial state vector
 real(rkind),intent(inout)          :: xMin,xMax                ! brackets of the root
 real(rkind),intent(in)             :: fScale(:)                ! function scaling vector
 real(rkind),intent(in)             :: xScale(:)                ! "variable" scaling vector, i.e., for state variables
 real(rkind),intent(in)             :: rVec(:)   ! NOTE: qp     ! residual vector
 real(rkind),intent(in)             :: sMul(:)   ! NOTE: qp     ! state vector multiplier (used in the residual calculations)
 real(rkind),intent(inout)          :: dMat(:)                  ! diagonal matrix (excludes flux derivatives)
 real(rkind),intent(in)             :: fOld                     ! old function evaluation
 ! input: data structures
 type(model_options),intent(in)  :: model_decisions(:)       ! model decisions
 type(var_i),        intent(in)  :: type_data                ! type of vegetation and soil
 type(var_d),        intent(in)  :: attr_data                ! spatial attributes
 type(var_dlength),  intent(in)  :: mpar_data                ! model parameters
 type(var_d),        intent(in)  :: forc_data                ! model forcing data
 type(var_dlength),  intent(in)  :: bvar_data                ! model variables for the local basin
 type(var_dlength),  intent(in)  :: prog_data                ! prognostic variables for a local HRU
 ! output: data structures
 type(var_ilength),intent(inout) :: indx_data                ! indices defining model states and layers
 type(var_dlength),intent(inout) :: diag_data                ! diagnostic variables for a local HRU
 type(var_dlength),intent(inout) :: flux_data                ! model fluxes for a local HRU
 type(var_dlength),intent(inout) :: deriv_data               ! derivatives in model fluxes w.r.t. relevant state variables
 ! input-output: baseflow
 integer(i4b),intent(inout)      :: ixSaturation             ! index of the lowest saturated layer (NOTE: only computed on the first iteration)
 real(rkind),intent(inout)          :: dBaseflow_dMatric(:,:)   ! derivative in baseflow w.r.t. matric head (s-1)
 ! output: flux and residual vectors
 real(rkind),intent(out)            :: stateVecNew(:)           ! new state vector
 real(rkind),intent(out)            :: fluxVecNew(:)            ! new flux vector
 real(rkind),intent(out)            :: resSinkNew(:)            ! sink terms on the RHS of the flux equation
 real(rkind),intent(out)            :: resVecNew(:) ! NOTE: qp  ! new residual vector
 real(rkind),intent(out)            :: fNew                     ! new function evaluation
 logical(lgt),intent(out)        :: converged                ! convergence flag
 ! output: error control
 integer(i4b),intent(out)        :: err                      ! error code
 character(*),intent(out)        :: message                  ! error message
 ! --------------------------------------------------------------------------------------------------------------------------------
 ! local variables
 ! --------------------------------------------------------------------------------------------------------------------------------
 ! Jacobian matrix
 logical(lgt),parameter          :: doNumJacobian=.false.    ! flag to compute the numerical Jacobian matrix
 logical(lgt),parameter          :: testBandDiagonal=.false. ! flag to test the band diagonal Jacobian matrix
 real(rkind)                        :: nJac(nState,nState)      ! numerical Jacobian matrix
 real(rkind)                        :: aJac(nLeadDim,nState)      ! Jacobian matrix
 real(rkind)                        :: aJacScaled(nLeadDim,nState)      ! Jacobian matrix (scaled)
 real(rkind)                        :: aJacScaledTemp(nLeadDim,nState)  ! Jacobian matrix (scaled) -- temporary copy since decomposed in lapack
 ! solution/step vectors
 real(rkind),dimension(nState)      :: rVecScaled               ! residual vector (scaled)
 real(rkind),dimension(nState)      :: newtStepScaled           ! full newton step (scaled)
 ! step size refinement
 logical(lgt)                    :: doRefine                 ! flag for step refinement
 integer(i4b),parameter          :: ixLineSearch=1001        ! step refinement = line search
 integer(i4b),parameter          :: ixTrustRegion=1002       ! step refinement = trust region
 integer(i4b),parameter          :: ixStepRefinement=ixLineSearch   ! decision for the numerical solution
 ! general
 integer(i4b)                    :: mSoil                    ! number of soil layers in solution vector
 integer(i4b)                    :: iLayer                   ! row index
 integer(i4b)                    :: jLayer                   ! column index
 logical(lgt)                    :: globalPrintFlagInit      ! initial global print flag
 character(LEN=256)              :: cmessage                 ! error message of downwind routine
 ! --------------------------------------------------------------------------------------------------------------------------------
 ! associations to information in data structures
 associate(ixGroundwater => model_decisions(iLookDECISIONS%groundwatr)%iDecision)  ! intent(in): [i4b] groundwater parameterization
 ! --------------------------------------------------------------------------------------------------------------------------------
 ! initialize error control
 err=0; message='summaSolve/'

 ! get the number of soil layers in the solution vector
 mSoil = size(indx_data%var(iLookINDEX%ixMatOnly)%dat)

 ! initialize the global print flag
 globalPrintFlagInit=globalPrintFlag

 ! -----
 ! * compute the Jacobian matrix...
 ! --------------------------------

 ! compute the analytical Jacobian matrix
 ! NOTE: The derivatives were computed in the previous call to computFlux
 !       This occurred either at the call to eval8summa at the start of systemSolv
 !        or in the call to eval8summa in the previous iteration (within lineSearchRefinement or trustRegionRefinement)
 call computJacob(&
                  ! input: model control
                  dt,                             & ! intent(in):    length of the time step (seconds)
                  nSnow,                          & ! intent(in):    number of snow layers
                  nSoil,                          & ! intent(in):    number of soil layers
                  nLayers,                        & ! intent(in):    total number of layers
                  computeVegFlux,                 & ! intent(in):    flag to indicate if we need to compute fluxes over vegetation
                  (ixGroundwater==qbaseTopmodel), & ! intent(in):    flag to indicate if we need to compute baseflow
                  ixMatrix,                       & ! intent(in):    form of the Jacobian matrix
                  ! input: data structures
                  indx_data,                      & ! intent(in):    index data
                  prog_data,                      & ! intent(in):    model prognostic variables for a local HRU
                  diag_data,                      & ! intent(in):    model diagnostic variables for a local HRU
                  deriv_data,                     & ! intent(in):    derivatives in model fluxes w.r.t. relevant state variables
                  dBaseflow_dMatric,              & ! intent(in):    derivative in baseflow w.r.t. matric head (s-1)
                  ! input-output: Jacobian and its diagonal
                  dMat,                           & ! intent(inout): diagonal of the Jacobian matrix
                  aJac,                           & ! intent(out):   Jacobian matrix
                  ! output: error control
                  err,cmessage)                     ! intent(out):   error code and error message
 if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

 ! compute the numerical Jacobian matrix
 if(doNumJacobian)then
  globalPrintFlag=.false.
  call numJacobian(stateVecTrial,dMat,nJac,err,cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
  globalPrintFlag=globalPrintFlagInit
 endif

 ! test the band diagonal matrix
 if(testBandDiagonal)then
  call testBandMat(check=.true.,err=err,message=cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
 endif

 ! -----
 ! * solve linear system...
 ! ------------------------

 ! scale the residual vector
 rVecScaled(1:nState) = fScale(:)*real(rVec(:), rkind)   ! NOTE: residual vector is in quadruple precision

 ! scale matrices
 call scaleMatrices(ixMatrix,nState,aJac,fScale,xScale,aJacScaled,err,cmessage)
 if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

 if(globalPrintFlag .and. ixMatrix==ixBandMatrix)then
  print*, '** SCALED banded analytical Jacobian:'
  write(*,'(a4,1x,100(i17,1x))') 'xCol', (iLayer, iLayer=iJac1,iJac2)
  do iLayer=kl+1,nBands
   write(*,'(i4,1x,100(e17.10,1x))') iLayer, (aJacScaled(iLayer,jLayer),jLayer=min(iJac1,nState),min(iJac2,nState))
  end do
 end if

 ! copy the scaled matrix, since it is decomposed in lapackSolv
 aJacScaledTemp = aJacScaled

 ! compute the newton step: use the lapack routines to solve the linear system A.X=B
 call lapackSolv(ixMatrix,nState,aJacScaledTemp,-rVecScaled,newtStepScaled,err,cmessage)
 if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

 if(globalPrintFlag)&
 write(*,'(a,1x,10(e17.10,1x))') 'newtStepScaled = ', newtStepScaled(min(iJac1,nState):min(iJac2,nState))
 !print*, 'PAUSE'; read(*,*)

 ! -----
 ! * update, evaluate, and refine the state vector...
 ! --------------------------------------------------

 ! initialize the flag for step refinement
 doRefine=.true.

 ! * case 1: state vector
 ! compute the flux vector and the residual, and (if necessary) refine the iteration increment
 ! NOTE: in 99.9% of cases newtStep will be used (no refinement)
 if(size(stateVecTrial)>1)then

  ! try to backtrack
  select case(ixStepRefinement)
   case(ixLineSearch);  call lineSearchRefinement( doRefine,stateVecTrial,newtStepScaled,aJacScaled,rVecScaled,fOld,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,cmessage)
   case(ixTrustRegion); call trustRegionRefinement(doRefine,stateVecTrial,newtStepScaled,aJacScaled,rVecScaled,fOld,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,cmessage)
   case default; err=20; message=trim(message)//'unable to identify numerical solution'; return
  end select

  ! check warnings: negative error code = warning; in this case back-tracked to the original value
  ! NOTE: Accept the full newton step if back-tracked to the original value
  if(err<0)then
   doRefine=.false.;    call lineSearchRefinement( doRefine,stateVecTrial,newtStepScaled,aJacScaled,rVecScaled,fOld,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,cmessage)
  end if

 ! * case 2: scalar
 else
  call safeRootfinder(stateVecTrial,rVecScaled,newtStepScaled,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
 endif

 ! check errors
 if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

 ! end association to info in data structures
 end associate

 contains

  ! *********************************************************************************************************
  ! * internal subroutine lineSearchRefinement: refine the iteration increment using line searches
  ! *********************************************************************************************************
  subroutine lineSearchRefinement(doLineSearch,stateVecTrial,newtStepScaled,aJacScaled,rVecScaled,fOld,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,message)
  ! provide access to the matrix routines
  USE matrixOper_module, only: computeGradient
  implicit none
  ! input
  logical(lgt),intent(in)        :: doLineSearch             ! flag to do the line search
  real(rkind),intent(in)            :: stateVecTrial(:)         ! trial state vector
  real(rkind),intent(in)            :: newtStepScaled(:)        ! scaled newton step
  real(rkind),intent(in)            :: aJacScaled(:,:)          ! scaled jacobian matrix
  real(rkind),intent(in)            :: rVecScaled(:)            ! scaled residual vector
  real(rkind),intent(in)            :: fOld                     ! old function value
  ! output
  real(rkind),intent(out)           :: stateVecNew(:)           ! new state vector
  real(rkind),intent(out)           :: fluxVecNew(:)            ! new flux vector
  real(rkind),intent(out)           :: resVecNew(:) ! NOTE: qp  ! new residual vector
  real(rkind),intent(out)           :: fNew                     ! new function evaluation
  logical(lgt),intent(out)       :: converged                ! convergence flag
  integer(i4b),intent(out)       :: err                      ! error code
  character(*),intent(out)       :: message                  ! error message
  ! --------------------------------------------------------------------------------------------------------
  ! local
  character(len=256)             :: cmessage                 ! error message of downwind routine
  real(rkind)                       :: gradScaled(nState)       ! scaled gradient
  real(rkind)                       :: xInc(nState)             ! iteration increment (re-scaled to original units of the state vector)
  logical(lgt)                   :: feasible                 ! flag to denote the feasibility of the solution
  integer(i4b)                   :: iLine                    ! line search index
  integer(i4b),parameter         :: maxLineSearch=5          ! maximum number of backtracks
  real(rkind),parameter             :: alpha=1.e-4_rkind           ! check on gradient
  real(rkind)                       :: xLambda                  ! backtrack magnitude
  real(rkind)                       :: xLambdaTemp              ! temporary backtrack magnitude
  real(rkind)                       :: slopeInit                ! initial slope
  real(rkind)                       :: rhs1,rhs2                ! rhs used to compute the cubic
  real(rkind)                       :: aCoef,bCoef              ! coefficients in the cubic
  real(rkind)                       :: disc                     ! temporary variable used in cubic
  real(rkind)                       :: xLambdaPrev              ! previous lambda value (used in the cubic)
  real(rkind)                       :: fPrev                    ! previous function evaluation (used in the cubic)
  ! --------------------------------------------------------------------------------------------------------
  ! initialize error control
  err=0; message='lineSearchRefinement/'

  ! check the need to compute the line search
  if(doLineSearch)then

   ! compute the gradient of the function vector
   call computeGradient(ixMatrix,nState,aJacScaled,rVecScaled,gradScaled,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! compute the initial slope
   slopeInit = dot_product(gradScaled,newtStepScaled)

  end if  ! if computing the line search

  ! initialize lambda
  xLambda=1._rkind

  ! ***** LINE SEARCH LOOP...
  lineSearch: do iLine=1,maxLineSearch  ! try to refine the function by shrinking the step size

   ! back-track along the search direction
   ! NOTE: start with back-tracking the scaled step
   xInc(:) = xLambda*newtStepScaled(:)

   ! re-scale the iteration increment
   xInc(:) = xInc(:)*xScale(:)

   ! if enthalpy, then need to convert the iteration increment to temperature
   !if(nrgFormulation==ix_enthalpy) xInc(ixNrgOnly) = xInc(ixNrgOnly)/dMat(ixNrgOnly)

   ! impose solution constraints
   ! NOTE: we may not need to do this (or at least, do ALL of this), as we can probably rely on the line search here
   !  (especially the feasibility check)
   call imposeConstraints(stateVecTrial,xInc,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! compute the iteration increment
   stateVecNew = stateVecTrial + xInc

   ! compute the residual vector and function
   ! NOTE: This calls eval8summa in an internal subroutine
   !       The internal sub routine has access to all data
   !       Hence, we only need to include the variables of interest in lineSearch
   call eval8summa_wrapper(stateVecNew,fluxVecNew,resVecNew,fNew,feasible,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! check line search
   if(globalPrintFlag)then
    write(*,'(a,1x,i4,1x,e17.10)' ) 'iLine, xLambda                 = ', iLine, xLambda
    write(*,'(a,1x,10(e17.10,1x))') 'fOld,fNew                      = ', fOld,fNew
    write(*,'(a,1x,10(e17.10,1x))') 'fold + alpha*slopeInit*xLambda = ', fold + alpha*slopeInit*xLambda
    write(*,'(a,1x,10(e17.10,1x))') 'resVecNew                      = ', resVecNew(min(iJac1,nState):min(iJac2,nState))
    write(*,'(a,1x,10(e17.10,1x))') 'xInc                           = ', xInc(min(iJac1,nState):min(iJac2,nState))
   end if

   ! check feasibility
   if(.not.feasible) cycle

   ! check convergence
   ! NOTE: some efficiency gains possible by scaling the full newton step outside the line search loop
   converged = checkConv(resVecNew,newtStepScaled*xScale,stateVecNew)
   if(converged) return

   ! early return if not computing the line search
   if(.not.doLineSearch) return

   ! check if the function is accepted
   if(fNew < fold + alpha*slopeInit*xLambda) return

   ! ***
   ! *** IF GET TO HERE WE BACKTRACK
   !      --> all remaining code simply computes the restricted step multiplier (xLambda)

   ! first backtrack: use quadratic
   if(iLine==1)then
    xLambdaTemp = -slopeInit / (2._rkind*(fNew - fOld - slopeInit) )
    if(xLambdaTemp > 0.5_rkind*xLambda) xLambdaTemp = 0.5_rkind*xLambda

   ! subsequent backtracks: use cubic
   else

    ! check that we did not back-track all the way back to the original value
    if(iLine==maxLineSearch)then
     message=trim(message)//'backtracked all the way back to the original value'
     err=-20; return
    end if

    ! define rhs
    rhs1 = fNew - fOld - xLambda*slopeInit
    rhs2 = fPrev - fOld - xLambdaPrev*slopeInit

    ! define coefficients
    aCoef = (rhs1/(xLambda*xLambda) - rhs2/(xLambdaPrev*xLambdaPrev))/(xLambda - xLambdaPrev)
    bCoef = (-xLambdaPrev*rhs1/(xLambda*xLambda) + xLambda*rhs2/(xLambdaPrev*xLambdaPrev)) / (xLambda - xLambdaPrev)

    ! check if a quadratic
    if(aCoef==0._rkind)then
     xLambdaTemp = -slopeInit/(2._rkind*bCoef)

    ! calculate cubic
    else
     disc = bCoef*bCoef - 3._rkind*aCoef*slopeInit
     if(disc < 0._rkind)then
      xLambdaTemp = 0.5_rkind*xLambda
     else
      xLambdaTemp = (-bCoef + sqrt(disc))/(3._rkind*aCoef)
     end if
    end if  ! calculating cubic

    ! constrain to <= 0.5*xLambda
    if(xLambdaTemp > 0.5_rkind*xLambda) xLambdaTemp=0.5_rkind*xLambda

   end if  ! subsequent backtracks

   ! save results
   xLambdaPrev = xLambda
   fPrev = fNew

   ! constrain lambda
   xLambda = max(xLambdaTemp, 0.1_rkind*xLambda)

  end do lineSearch  ! backtrack loop

  end subroutine lineSearchRefinement


  ! *********************************************************************************************************
  ! * internal subroutine trustRegionRefinement: refine the iteration increment using trust regions
  ! *********************************************************************************************************
  subroutine trustRegionRefinement(doTrustRefinement,stateVecTrial,newtStepScaled,aJacScaled,rVecScaled,fOld,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,message)
  ! provide access to the matrix routines
  USE matrixOper_module, only: lapackSolv
  USE matrixOper_module, only: computeGradient
  implicit none
  ! input
  logical(lgt),intent(in)        :: doTrustRefinement        ! flag to refine using trust regions
  real(rkind),intent(in)            :: stateVecTrial(:)         ! trial state vector
  real(rkind),intent(in)            :: newtStepScaled(:)        ! scaled newton step
  real(rkind),intent(in)            :: aJacScaled(:,:)          ! scaled jacobian matrix
  real(rkind),intent(in)            :: rVecScaled(:)            ! scaled residual vector
  real(rkind),intent(in)            :: fOld                     ! old function value
  ! output
  real(rkind),intent(out)           :: stateVecNew(:)           ! new state vector
  real(rkind),intent(out)           :: fluxVecNew(:)            ! new flux vector
  real(rkind),intent(out)           :: resVecNew(:) ! NOTE: qp  ! new residual vector
  real(rkind),intent(out)           :: fNew                     ! new function evaluation
  logical(lgt),intent(out)       :: converged                ! convergence flag
  integer(i4b),intent(out)       :: err                      ! error code
  character(*),intent(out)       :: message                  ! error message
  ! --------------------------------------------------------------------------------------------------------
  ! local variables

  ! .. needed ..


  ! --------------------------------------------------------------------------------------------------------
  err=0; message='trustRegionRefinement/'

  ! check the need to refine the step
  if(doTrustRefinement)then

   ! (check vectors)
   if(size(stateVecTrial)/=nState .or. size(newtStepScaled)/=nState .or. size(rVecScaled)/=nState)then
    message=trim(message)//'unexpected size of input vectors'
    err=20; return
   endif

   ! (check matrix)
   if(size(aJacScaled,1)/=nState .or. size(aJacScaled,2)/=nState)then
    message=trim(message)//'unexpected size of Jacobian matrix'
    err=20; return
   endif

   ! dummy check for the function
   if(fold==realMissing) print*, 'missing'

   ! dummy
   stateVecNew = realMissing
   fluxVecNew  = realMissing
   resVecNew   = quadMissing
   fNew        = realMissing
   converged   = .true.


  endif  ! if doing the trust region refinement

  message=trim(message)//'routine not implemented yet'
  err=20; return



  end subroutine trustRegionRefinement


  ! *********************************************************************************************************
  ! * internal subroutine safeRootfinder: refine the 1-d iteration increment using brackets
  ! *********************************************************************************************************
  subroutine safeRootfinder(stateVecTrial,rVecscaled,newtStepScaled,stateVecNew,fluxVecNew,resVecNew,fNew,converged,err,message)
  USE,intrinsic :: ieee_arithmetic,only:ieee_is_nan          ! IEEE arithmetic (check NaN)
  USE globalData,only:dNaN                                   ! double precision NaN
  implicit none
  ! input
  real(rkind),intent(in)            :: stateVecTrial(:)         ! trial state vector
  real(rkind),intent(in)            :: rVecScaled(:)            ! scaled residual vector
  real(rkind),intent(in)            :: newtStepScaled(:)        ! scaled newton step
  ! output
  real(rkind),intent(out)           :: stateVecNew(:)           ! new state vector
  real(rkind),intent(out)           :: fluxVecNew(:)            ! new flux vector
  real(rkind),intent(out)           :: resVecNew(:) ! NOTE: qp  ! new residual vector
  real(rkind),intent(out)           :: fNew                     ! new function evaluation
  logical(lgt),intent(out)       :: converged                ! convergence flag
  integer(i4b),intent(out)       :: err                      ! error code
  character(*),intent(out)       :: message                  ! error message
  ! --------------------------------------------------------------------------------------------------------
  ! local variables
  character(len=256)             :: cmessage                 ! error message of downwind routine
  real(rkind),parameter             :: relTolerance=0.005_rkind    ! force bi-section if trial is slightly larger than (smaller than) xmin (xmax)
  real(rkind)                       :: xTolerance               ! relTolerance*(xmax-xmin)
  real(rkind)                       :: xInc(nState)             ! iteration increment (re-scaled to original units of the state vector)
  real(rkind)                       :: rVec(nState)             ! residual vector (re-scaled to original units of the state equation)
  logical(lgt)                   :: feasible                 ! feasibility of the solution
  logical(lgt)                   :: doBisection              ! flag to do the bi-section
  logical(lgt)                   :: bracketsDefined          ! flag to define if the brackets are defined
  !integer(i4b)                  :: iCheck                   ! check the model state variables (not used)
  integer(i4b),parameter         :: nCheck=100               ! number of times to check the model state variables
  real(rkind),parameter             :: delX=1._rkind               ! trial increment
  !real(rkind)                      :: xIncrement(nState)       ! trial increment (not used)
  ! --------------------------------------------------------------------------------------------------------
  err=0; message='safeRootfinder/'

  ! check scalar
  if(size(stateVecTrial)/=1 .or. size(rVecScaled)/=1 .or. size(newtStepScaled)/=1)then
   message=trim(message)//'unexpected size of input vectors'
   err=20; return
  endif

  ! initialize brackets to rkind precision NaN
  if(iter==1)then
   xMax = dNaN
   xMin = dNaN
  endif

  ! get the residual vector
  rVec = real(rVecScaled, rkind)*real(fScale, rkind)

  ! update brackets
  if(rVec(1)<0._rkind)then
   xMin = stateVecTrial(1)
  else
   xMax = stateVecTrial(1)
  endif

  ! get the iteration increment
  xInc = newtStepScaled*xScale

  ! *****
  ! * case 1: the iteration increment is the same sign as the residual vector
  if(xInc(1)*rVec(1) > 0._rkind)then

   ! get brackets if they do not exist
   if( ieee_is_nan(xMin) .or. ieee_is_nan(xMax) )then
    call getBrackets(stateVecTrial,stateVecNew,xMin,xMax,err,cmessage)
    if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
   endif

   ! use bi-section
   stateVecNew(1) = 0.5_rkind*(xMin + xMax)

  ! *****
  ! * case 2: the iteration increment is the correct sign
  else

   ! impose solution constraints
   call imposeConstraints(stateVecTrial,xInc,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! compute the iteration increment
   stateVecNew = stateVecTrial + xInc

  endif  ! if the iteration increment is the same sign as the residual vector

  ! bi-section
  bracketsDefined = ( .not.ieee_is_nan(xMin) .and. .not.ieee_is_nan(xMax) )  ! check that the brackets are defined
  if(bracketsDefined)then
   xTolerance  = relTolerance*(xMax-xMin)
   doBisection = (stateVecNew(1)<xMin+xTolerance .or. stateVecNew(1)>xMax-xTolerance)
   if(doBisection) stateVecNew(1) = 0.5_rkind*(xMin+xMax)
  endif

  ! evaluate summa
  call eval8summa_wrapper(stateVecNew,fluxVecNew,resVecNew,fNew,feasible,err,cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

  ! check feasibility (should be feasible because of the call to imposeConstraints
  if(.not.feasible)then; err=20; message=trim(message)//'infeasible solution'; return; endif

  ! check convergence
  converged = checkConv(resVecNew,xInc,stateVecNew)

  !write(*,'(a,1x,2(L1,1x),5(e20.8,1x))') 'bracketsDefined, doBisection, xMin, xMax, stateVecTrial, stateVecNew, xInc = ', &
  !                                        bracketsDefined, doBisection, xMin, xMax, stateVecTrial, stateVecNew, xInc
  !print*, 'PAUSE'; read(*,*)

  end subroutine safeRootfinder

  ! *********************************************************************************************************
  ! * internal subroutine getBrackets: get the brackets
  ! *********************************************************************************************************
  subroutine getBrackets(stateVecTrial,stateVecNew,xMin,xMax,err,message)
  USE,intrinsic :: ieee_arithmetic,only:ieee_is_nan          ! IEEE arithmetic (check NaN)
  implicit none
  ! dummies
  real(rkind),intent(in)            :: stateVecTrial(:)         ! trial state vector
  real(rkind),intent(out)           :: stateVecNew(:)           ! new state vector
  real(rkind),intent(out)           :: xMin,xMax                ! constraints
  integer(i4b),intent(inout)     :: err                      ! error code
  character(*),intent(out)       :: message                  ! error message
  ! locals
  integer(i4b)                   :: iCheck                   ! check the model state variables
  integer(i4b),parameter         :: nCheck=100               ! number of times to check the model state variables
  logical(lgt)                   :: feasible                 ! feasibility of the solution
  real(rkind),parameter             :: delX=1._rkind               ! trial increment
  real(rkind)                       :: xIncrement(nState)       ! trial increment
  ! initialize
  err=0; message='getBrackets/'

  ! initialize state vector
  stateVecNew = stateVecTrial

  ! get xIncrement
  xIncrement = -sign((/delX/),rVec)

  ! try the increment a few times
  do iCheck=1,nCheck

   ! impose solution constraints
   call imposeConstraints(stateVecNew,xIncrement,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! increment state vector
   stateVecNew = stateVecNew + xIncrement

   ! evaluate summa
   call eval8summa_wrapper(stateVecNew,fluxVecNew,resVecNew,fNew,feasible,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

   ! check that the trial value is feasible (should not happen because of the call to impose constraints)
   if(.not.feasible)then; message=trim(message)//'state vector is not feasible'; err=20; return; endif

   ! update brackets
   if(real(resVecNew(1), rkind)<0._rkind)then
    xMin = stateVecNew(1)
   else
    xMax = stateVecNew(1)
   endif

   ! print progress
   !print*, 'xMin, xMax, stateVecTrial, stateVecNew, resVecNew, xIncrement = ', &
   !         xMin, xMax, stateVecTrial, stateVecNew, resVecNew, xIncrement

   ! check that the brackets are defined
   if( .not.ieee_is_nan(xMin) .and. .not.ieee_is_nan(xMax) ) exit

   ! check that we found the brackets
   if(iCheck==nCheck)then
    message=trim(message)//'could not fix the problem where residual and iteration increment are of the same sign'
    err=20; return
   endif

  end do  ! multiple checks

  end subroutine getBrackets


  ! *********************************************************************************************************
  ! * internal subroutine numJacobian: compute the numerical Jacobian matrix
  ! *********************************************************************************************************
  subroutine numJacobian(stateVec,dMat,nJac,err,message)
  implicit none
  ! dummies
  real(rkind),intent(in)            :: stateVec(:)                ! trial state vector
  real(rkind),intent(in)            :: dMat(:)                    ! diagonal matrix
  ! output
  real(rkind),intent(out)           :: nJac(:,:)                  ! numerical Jacobian
  integer(i4b),intent(out)       :: err                        ! error code
  character(*),intent(out)       :: message                    ! error message
  ! ----------------------------------------------------------------------------------------------------------
  ! local
  character(len=256)             :: cmessage                   ! error message of downwind routine
  real(rkind),parameter             :: dx=1.e-8_rkind               ! finite difference increment
  real(rkind),dimension(nState)     :: stateVecPerturbed          ! perturbed state vector
  real(rkind),dimension(nState)     :: fluxVecInit,fluxVecJac     ! flux vector (mized units)
  real(rkind),dimension(nState)     :: resVecInit,resVecJac ! qp  ! residual vector (mixed units)
  real(rkind)                       :: func                       ! function value
  logical(lgt)                   :: feasible                   ! flag to denote the feasibility of the solution
  integer(i4b)                   :: iJac                       ! index of row of the Jacobian matrix
  integer(i4b),parameter         :: ixNumFlux=1001             ! named variable for the flux-based form of the numerical Jacobian
  integer(i4b),parameter         :: ixNumRes=1002              ! named variable for the residual-based form of the numerical Jacobian
  integer(i4b)                   :: ixNumType=ixNumRes         ! method used to calculate the numerical Jacobian
  ! ----------------------------------------------------------------------------------------------------------
  ! initialize error control
  err=0; message='numJacobian/'

  ! compute initial function evaluation
  call eval8summa_wrapper(stateVec,fluxVecInit,resVecInit,func,feasible,err,cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
  if(.not.feasible)then; message=trim(message)//'initial state vector not feasible'; err=20; return; endif

  ! get a copy of the state vector to perturb
  stateVecPerturbed(:) = stateVec(:)

  ! loop through state variables
  do iJac=1,nState

   !print*, 'iJac = ', iJac
   !globalPrintFlag = merge(.true.,.false., iJac==1)

   ! perturb state vector
   stateVecPerturbed(iJac) = stateVec(iJac) + dx

   ! compute function evaluation
   call eval8summa_wrapper(stateVecPerturbed,fluxVecJac,resVecJac,func,feasible,err,cmessage)
   if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)
   if(.not.feasible)then; message=trim(message)//'state vector not feasible'; err=20; return; endif
   !write(*,'(a,1x,2(f30.20,1x))') 'resVecJac(101:102)  = ', resVecJac(101:102)

   ! compute the row of the Jacobian matrix
   select case(ixNumType)
    case(ixNumRes);  nJac(:,iJac) = real(resVecJac - resVecInit, kind(rkind) )/dx  ! Jacobian based on residuals
    case(ixNumFlux); nJac(:,iJac) = -dt*(fluxVecJac(:) - fluxVecInit(:))/dx     ! Jacobian based on fluxes
    case default; err=20; message=trim(message)//'Jacobian option not found'; return
   end select

   ! if flux option then add in the diagonal matrix
   if(ixNumType==ixNumFlux) nJac(iJac,iJac) = nJac(iJac,iJac) + dMat(iJac)

   ! set the state back to the input value
   stateVecPerturbed(iJac) = stateVec(iJac)

  end do  ! (looping through state variables)

  ! print the Jacobian
  print*, '** numerical Jacobian:', ixNumType==ixNumRes
  write(*,'(a4,1x,100(i12,1x))') 'xCol', (iLayer, iLayer=min(iJac1,nState),min(iJac2,nState))
  do iLayer=min(iJac1,nState),min(iJac2,nState)
   write(*,'(i4,1x,100(e12.5,1x))') iLayer, nJac(min(iJac1,nState):min(iJac2,nState),iLayer)
  end do
  !print*, 'PAUSE: testing Jacobian'; read(*,*)

  end subroutine numJacobian

  ! *********************************************************************************************************
  ! * internal subroutine testBandMat: compute the full Jacobian matrix and decompose into a band matrix
  ! *********************************************************************************************************

  subroutine testBandMat(check,err,message)
  ! dummy variables
  logical(lgt),intent(in)         :: check                    ! flag to pause
  integer(i4b),intent(out)        :: err                      ! error code
  character(*),intent(out)        :: message                  ! error message
  ! local variables
  real(rkind)                        :: fullJac(nState,nState)   ! full Jacobian matrix
  real(rkind)                        :: bandJac(nLeadDim,nState) ! band Jacobian matrix
  integer(i4b)                    :: iState,jState            ! indices of the state vector
  character(LEN=256)              :: cmessage                 ! error message of downwind routine
  ! initialize error control
  err=0; message='testBandMat/'

  ! check
  if(nLeadDim==nState)then
   message=trim(message)//'do not expect nLeadDim==nState: check that are computing the band diagonal matrix'//&
                          ' (is forceFullMatrix==.true.?)'
   err=20; return
  endif

  ! compute the full Jacobian matrix
  call computJacob(&
                   ! input: model control
                   dt,                             & ! intent(in):    length of the time step (seconds)
                   nSnow,                          & ! intent(in):    number of snow layers
                   nSoil,                          & ! intent(in):    number of soil layers
                   nLayers,                        & ! intent(in):    total number of layers
                   computeVegFlux,                 & ! intent(in):    flag to indicate if we need to compute fluxes over vegetation
                   .false.,                        & ! intent(in):    flag to indicate if we need to compute baseflow
                   ixFullMatrix,                   & ! intent(in):    force full Jacobian matrix
                   ! input: data structures
                   indx_data,                      & ! intent(in):    index data
                   prog_data,                      & ! intent(in):    model prognostic variables for a local HRU
                   diag_data,                      & ! intent(in):    model diagnostic variables for a local HRU
                   deriv_data,                     & ! intent(in):    derivatives in model fluxes w.r.t. relevant state variables
                   dBaseflow_dMatric,              & ! intent(in):    derivative in baseflow w.r.t. matric head (s-1)
                   ! input-output: Jacobian and its diagonal
                   dMat,                           & ! intent(inout): diagonal of the Jacobian matrix
                   fullJac,                        & ! intent(out):   full Jacobian matrix
                   ! output: error control
                   err,cmessage)                     ! intent(out):   error code and error message
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

  ! initialize band matrix
  bandJac(:,:) = 0._rkind

  ! transfer into the lapack band diagonal structure
  do iState=1,nState
   do jState=max(1,iState-ku),min(nState,iState+kl)
    bandJac(kl + ku + 1 + jState - iState, iState) = fullJac(jState,iState)
   end do
  end do

  ! print results
  print*, '** test banded analytical Jacobian:'
  write(*,'(a4,1x,100(i17,1x))') 'xCol', (iState, iState=iJac1,iJac2)
  do iState=kl+1,nLeadDim; write(*,'(i4,1x,100(e17.10,1x))') iState, bandJac(iState,iJac1:iJac2); end do

  ! check if the need to pause
  if(check)then
   print*, 'PAUSE: testing banded analytical Jacobian'
   read(*,*)
  endif

  end subroutine testBandMat



  ! *********************************************************************************************************
  ! * internal subroutine eval8summa_wrapper: compute the right-hand-side vector
  ! *********************************************************************************************************
  ! NOTE: This is simply a wrapper routine for eval8summa, to reduce the number of calling arguments
  !       An internal subroutine, so have access to all data in the main subroutine
  subroutine eval8summa_wrapper(stateVecNew,fluxVecNew,resVecNew,fNew,feasible,err,message)
  USE eval8summa_module,only:eval8summa                      ! simulation of fluxes and residuals given a trial state vector
  implicit none
  ! input
  real(rkind),intent(in)            :: stateVecNew(:)           ! updated state vector
  ! output
  real(rkind),intent(out)           :: fluxVecNew(:)            ! updated flux vector
  real(rkind),intent(out)           :: resVecNew(:) ! NOTE: qp  ! updated residual vector
  real(rkind),intent(out)           :: fNew                     ! new function value
  logical(lgt),intent(out)       :: feasible                 ! flag to denote the feasibility of the solution
  integer(i4b),intent(out)       :: err                      ! error code
  character(*),intent(out)       :: message                  ! error message
  ! ----------------------------------------------------------------------------------------------------------
  ! local
  character(len=256)             :: cmessage                 ! error message of downwind routine
  ! ----------------------------------------------------------------------------------------------------------
  ! initialize error control
  err=0; message='eval8summa_wrapper/'

  ! compute the flux and the residual vector for a given state vector
  call eval8summa(&
                  ! input: model control
                  dt,                      & ! intent(in):    length of the time step (seconds)
                  nSnow,                   & ! intent(in):    number of snow layers
                  nSoil,                   & ! intent(in):    number of soil layers
                  nLayers,                 & ! intent(in):    total number of layers
                  nState,                  & ! intent(in):    total number of state variables
                  firstSubStep,            & ! intent(in):    flag to indicate if we are processing the first sub-step
                  firstFluxCall,           & ! intent(inout): flag to indicate if we are processing the first flux call
                  .false.,                 & ! intent(in):    flag to indicate if we are processing the first iteration in a splitting operation
                  computeVegFlux,          & ! intent(in):    flag to indicate if we need to compute fluxes over vegetation
                  scalarSolution,          & ! intent(in):    flag to indicate the scalar solution
                  ! input: state vectors
                  stateVecNew,             & ! intent(in):    updated model state vector
                  fScale,                  & ! intent(in):    function scaling vector
                  sMul,                    & ! intent(in):    state vector multiplier (used in the residual calculations)
                  ! input: data structures
                  model_decisions,         & ! intent(in):    model decisions
                  type_data,               & ! intent(in):    type of vegetation and soil
                  attr_data,               & ! intent(in):    spatial attributes
                  mpar_data,               & ! intent(in):    model parameters
                  forc_data,               & ! intent(in):    model forcing data
                  bvar_data,               & ! intent(in):    average model variables for the entire basin
                  prog_data,               & ! intent(in):    model prognostic variables for a local HRU
                  indx_data,               & ! intent(in):    index data
                  ! input-output: data structures
                  diag_data,               & ! intent(inout): model diagnostic variables for a local HRU
                  flux_data,               & ! intent(inout): model fluxes for a local HRU
                  deriv_data,              & ! intent(inout): derivatives in model fluxes w.r.t. relevant state variables
                  ! input-output: baseflow
                  ixSaturation,            & ! intent(inout): index of the lowest saturated layer (NOTE: only computed on the first iteration)
                  dBaseflow_dMatric,       & ! intent(out):   derivative in baseflow w.r.t. matric head (s-1)
                  ! output
                  feasible,                & ! intent(out):   flag to denote the feasibility of the solution
                  fluxVecNew,              & ! intent(out):   new flux vector
                  resSinkNew,              & ! intent(out):   additional (sink) terms on the RHS of the state equation
                  resVecNew,               & ! intent(out):   new residual vector
                  fNew,                    & ! intent(out):   new function evaluation
                  err,cmessage)              ! intent(out):   error control
  if(err/=0)then; message=trim(message)//trim(cmessage); return; end if  ! (check for errors)

  end subroutine eval8summa_wrapper


  ! *********************************************************************************************************
  ! internal function checkConv: check convergence based on the residual vector
  ! *********************************************************************************************************
  function checkConv(rVec,xInc,xVec)
  implicit none
  ! dummies
  real(rkind),intent(in)       :: rVec(:)                ! residual vector (mixed units)
  real(rkind),intent(in)       :: xInc(:)                ! iteration increment (mixed units)
  real(rkind),intent(in)       :: xVec(:)                ! state vector (mixed units)
  logical(lgt)              :: checkConv              ! flag to denote convergence
  ! locals
  real(rkind),dimension(mSoil) :: psiScale               ! scaling factor for matric head
  real(rkind),parameter        :: xSmall=1.e-0_rkind        ! a small offset
  real(rkind),parameter        :: scalarTighten=0.1_rkind   ! scaling factor for the scalar solution
  real(rkind)                  :: soilWatbalErr          ! error in the soil water balance
  real(rkind)                  :: canopy_max             ! absolute value of the residual in canopy water (kg m-2)
  real(rkind),dimension(1)     :: energy_max             ! maximum absolute value of the energy residual (J m-3)
  real(rkind),dimension(1)     :: liquid_max             ! maximum absolute value of the volumetric liquid water content residual (-)
  real(rkind),dimension(1)     :: matric_max             ! maximum absolute value of the matric head iteration increment (m)
  real(rkind)                  :: aquifer_max            ! absolute value of the residual in aquifer water (m)
  logical(lgt)              :: canopyConv             ! flag for canopy water balance convergence
  logical(lgt)              :: watbalConv             ! flag for soil water balance convergence
  logical(lgt)              :: liquidConv             ! flag for residual convergence
  logical(lgt)              :: matricConv             ! flag for matric head convergence
  logical(lgt)              :: energyConv             ! flag for energy convergence
  logical(lgt)              :: aquiferConv            ! flag for aquifer water balance convergence
  ! -------------------------------------------------------------------------------------------------------------------------------------------------
  ! association to variables in the data structures
  associate(&
  ! convergence parameters
  absConvTol_liquid       => mpar_data%var(iLookPARAM%absConvTol_liquid)%dat(1)     ,&  ! intent(in): [dp] absolute convergence tolerance for vol frac liq water (-)
  absConvTol_matric       => mpar_data%var(iLookPARAM%absConvTol_matric)%dat(1)     ,&  ! intent(in): [dp] absolute convergence tolerance for matric head        (m)
  absConvTol_energy       => mpar_data%var(iLookPARAM%absConvTol_energy)%dat(1)     ,&  ! intent(in): [dp] absolute convergence tolerance for energy             (J m-3)
  ! layer depth
  mLayerDepth             => prog_data%var(iLookPROG%mLayerDepth)%dat               ,&  ! intent(in): [dp(:)] depth of each layer in the snow-soil sub-domain (m)
  ! model indices
  ixAqWat                 => indx_data%var(iLookINDEX%ixAqWat)%dat(1)               ,&  ! intent(in): [i4b]    index of aquifer storage state variable
  ixCasNrg                => indx_data%var(iLookINDEX%ixCasNrg)%dat(1)              ,&  ! intent(in): [i4b]    index of canopy air space energy state variable
  ixVegNrg                => indx_data%var(iLookINDEX%ixVegNrg)%dat(1)              ,&  ! intent(in): [i4b]    index of canopy energy state variable
  ixVegHyd                => indx_data%var(iLookINDEX%ixVegHyd)%dat(1)              ,&  ! intent(in): [i4b]    index of canopy hydrology state variable (mass)
  ixNrgOnly               => indx_data%var(iLookINDEX%ixNrgOnly)%dat                ,&  ! intent(in): [i4b(:)] list of indices for all energy states
  ixHydOnly               => indx_data%var(iLookINDEX%ixHydOnly)%dat                ,&  ! intent(in): [i4b(:)] list of indices for all hydrology states
  ixMatOnly               => indx_data%var(iLookINDEX%ixMatOnly)%dat                ,&  ! intent(in): [i4b(:)] list of indices for matric head state variables in the state vector
  ixMatricHead            => indx_data%var(iLookINDEX%ixMatricHead)%dat              &  ! intent(in): [i4b(:)] list of indices for matric head in the soil vector

  ) ! making associations with variables in the data structures
  ! -------------------------------------------------------------------------------------------------------------------------------------------------

  ! check convergence based on the canopy water balance
  if(ixVegHyd/=integerMissing)then
   canopy_max = real(abs(rVec(ixVegHyd)), rkind)*iden_water
   canopyConv = (canopy_max    < absConvTol_liquid)  ! absolute error in canopy water balance (mm)
  else
   canopy_max = realMissing
   canopyConv = .true.
  endif

  ! check convergence based on the residuals for energy (J m-3)
  if(size(ixNrgOnly)>0)then
   energy_max = real(maxval(abs( rVec(ixNrgOnly) )), rkind)
   energyConv = (energy_max(1) < absConvTol_energy)  ! (based on the residual)
  else
   energy_max = realMissing
   energyConv = .true.
  endif

  ! check convergence based on the residuals for volumetric liquid water content (-)
  if(size(ixHydOnly)>0)then
   liquid_max = real(maxval(abs( rVec(ixHydOnly) ) ), rkind)
   ! (tighter convergence for the scalar solution)
   if(scalarSolution)then
    liquidConv = (liquid_max(1) < absConvTol_liquid*scalarTighten)   ! (based on the residual)
   else
    liquidConv = (liquid_max(1) < absConvTol_liquid)                 ! (based on the residual)
   endif
  else
   liquid_max = realMissing
   liquidConv = .true.
  endif

  ! check convergence based on the iteration increment for matric head
  ! NOTE: scale by matric head to avoid unnecessairly tight convergence when there is no water
  if(size(ixMatOnly)>0)then
   psiScale   = abs( xVec(ixMatOnly) ) + xSmall ! avoid divide by zero
   matric_max = maxval(abs( xInc(ixMatOnly)/psiScale ) )
   matricConv = (matric_max(1) < absConvTol_matric)  ! NOTE: based on iteration increment
  else
   matric_max = realMissing
   matricConv = .true.
  endif

  ! check convergence based on the soil water balance error (m)
  if(size(ixMatOnly)>0)then
   soilWatBalErr = sum( real(rVec(ixMatOnly), rkind)*mLayerDepth(nSnow+ixMatricHead) )
   watbalConv    = (abs(soilWatbalErr) < absConvTol_liquid)  ! absolute error in total soil water balance (m)
  else
   soilWatbalErr = realMissing
   watbalConv    = .true.
  endif

  ! check convergence based on the aquifer storage
  if(ixAqWat/=integerMissing)then
   aquifer_max = real(abs(rVec(ixAqWat)), rkind)*iden_water
   aquiferConv = (aquifer_max    < absConvTol_liquid)  ! absolute error in aquifer water balance (mm)
  else
   aquifer_max = realMissing
   aquiferConv = .true.
  endif

  ! final convergence check
  checkConv = (canopyConv .and. watbalConv .and. matricConv .and. liquidConv .and. energyConv .and. aquiferConv)

  ! print progress towards solution
  if(globalPrintFlag)then
   write(*,'(a,1x,i4,1x,7(e15.5,1x),7(L1,1x))') 'check convergence: ', iter, &
    fNew, matric_max(1), liquid_max(1), energy_max(1), canopy_max, aquifer_max, soilWatBalErr, matricConv, liquidConv, energyConv, watbalConv, canopyConv, aquiferConv, watbalConv
  endif

  ! end associations with variables in the data structures
  end associate

  end function checkConv


  ! *********************************************************************************************************
  ! internal subroutine imposeConstraints: impose solution constraints
  ! *********************************************************************************************************
  subroutine imposeConstraints(stateVecTrial,xInc,err,message)
  ! external functions
  USE snow_utils_module,only:fracliquid                           ! compute the fraction of liquid water at a given temperature (snow)
  USE soil_utils_module,only:crit_soilT                           ! compute the critical temperature below which ice exists
  implicit none
  ! dummies
  real(rkind),intent(in)             :: stateVecTrial(:)             ! trial state vector
  real(rkind),intent(inout)          :: xInc(:)                      ! iteration increment
  integer(i4b),intent(out)        :: err                          ! error code
  character(*),intent(out)        :: message                      ! error message
  ! -----------------------------------------------------------------------------------------------------
  ! temporary variables for model constraints
  real(rkind)                        :: cInc                         ! constrained temperature increment (K) -- simplified bi-section
  real(rkind)                        :: xIncFactor                   ! scaling factor for the iteration increment (-)
  integer(i4b)                    :: iMax(1)                      ! index of maximum temperature
  real(rkind)                        :: scalarTemp                   ! temperature of an individual snow layer (K)
  real(rkind)                        :: volFracLiq                   ! volumetric liquid water content of an individual snow layer (-)
  logical(lgt),dimension(nSnow)   :: drainFlag                    ! flag to denote when drainage exceeds available capacity
  logical(lgt),dimension(nSoil)   :: crosFlag                     ! flag to denote temperature crossing from unfrozen to frozen (or vice-versa)
  logical(lgt)                    :: crosTempVeg                  ! flag to denoote where temperature crosses the freezing point
  real(rkind)                        :: xPsi00                       ! matric head after applying the iteration increment (m)
  real(rkind)                        :: TcSoil                       ! critical point when soil begins to freeze (K)
  real(rkind)                        :: critDiff                     ! temperature difference from critical (K)
  real(rkind),parameter              :: epsT=1.e-7_rkind                ! small interval above/below critical (K)
  real(rkind),parameter              :: zMaxTempIncrement=1._rkind      ! maximum temperature increment (K)
  ! indices of model state variables
  integer(i4b)                    :: iState                       ! index of state within a specific variable type
  integer(i4b)                    :: ixNrg,ixLiq                  ! index of energy and mass state variables in full state vector
  ! indices of model layers
  integer(i4b)                    :: iLayer                       ! index of model layer
  ! -----------------------------------------------------------------------------------------------------
  ! associate variables with indices of model state variables
  associate(&
  ixNrgOnly               => indx_data%var(iLookINDEX%ixNrgOnly)%dat                ,& ! intent(in): [i4b(:)] list of indices in the state subset for energy states
  ixHydOnly               => indx_data%var(iLookINDEX%ixHydOnly)%dat                ,& ! intent(in): [i4b(:)] list of indices in the state subset for hydrology states
  ixMatOnly               => indx_data%var(iLookINDEX%ixMatOnly)%dat                ,& ! intent(in): [i4b(:)] list of indices in the state subset for matric head states
  ixMassOnly              => indx_data%var(iLookINDEX%ixMassOnly)%dat               ,& ! intent(in): [i4b(:)] list of indices in the state subset for canopy storage states
  ixStateType_subset      => indx_data%var(iLookINDEX%ixStateType_subset)%dat       ,& ! intent(in): [i4b(:)] named variables defining the states in the subset
  ! indices for specific state variables
  ixCasNrg                => indx_data%var(iLookINDEX%ixCasNrg)%dat(1)              ,& ! intent(in): [i4b] index of canopy air space energy state variable
  ixVegNrg                => indx_data%var(iLookINDEX%ixVegNrg)%dat(1)              ,& ! intent(in): [i4b] index of canopy energy state variable
  ixVegHyd                => indx_data%var(iLookINDEX%ixVegHyd)%dat(1)              ,& ! intent(in): [i4b] index of canopy hydrology state variable (mass)
  ixTopNrg                => indx_data%var(iLookINDEX%ixTopNrg)%dat(1)              ,& ! intent(in): [i4b] index of upper-most energy state in the snow-soil subdomain
  ixTopHyd                => indx_data%var(iLookINDEX%ixTopHyd)%dat(1)              ,& ! intent(in): [i4b] index of upper-most hydrology state in the snow-soil subdomain
  ! vector of energy indices for the snow and soil domains
  ! NOTE: states not in the subset are equal to integerMissing
  ixSnowSoilNrg           => indx_data%var(iLookINDEX%ixSnowSoilNrg)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for energy state variables in the snow+soil domain
  ixSnowOnlyNrg           => indx_data%var(iLookINDEX%ixSnowOnlyNrg)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for energy state variables in the snow domain
  ixSoilOnlyNrg           => indx_data%var(iLookINDEX%ixSoilOnlyNrg)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for energy state variables in the soil domain
  ! vector of hydrology indices for the snow and soil domains
  ! NOTE: states not in the subset are equal to integerMissing
  ixSnowSoilHyd           => indx_data%var(iLookINDEX%ixSnowSoilHyd)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for hydrology state variables in the snow+soil domain
  ixSnowOnlyHyd           => indx_data%var(iLookINDEX%ixSnowOnlyHyd)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for hydrology state variables in the snow domain
  ixSoilOnlyHyd           => indx_data%var(iLookINDEX%ixSoilOnlyHyd)%dat            ,& ! intent(in): [i4b(:)] index in the state subset for hydrology state variables in the soil domain
  ! number of state variables of a specific type
  nSnowSoilNrg            => indx_data%var(iLookINDEX%nSnowSoilNrg )%dat(1)         ,& ! intent(in): [i4b]    number of energy state variables in the snow+soil domain
  nSnowOnlyNrg            => indx_data%var(iLookINDEX%nSnowOnlyNrg )%dat(1)         ,& ! intent(in): [i4b]    number of energy state variables in the snow domain
  nSoilOnlyNrg            => indx_data%var(iLookINDEX%nSoilOnlyNrg )%dat(1)         ,& ! intent(in): [i4b]    number of energy state variables in the soil domain
  nSnowSoilHyd            => indx_data%var(iLookINDEX%nSnowSoilHyd )%dat(1)         ,& ! intent(in): [i4b]    number of hydrology variables in the snow+soil domain
  nSnowOnlyHyd            => indx_data%var(iLookINDEX%nSnowOnlyHyd )%dat(1)         ,& ! intent(in): [i4b]    number of hydrology variables in the snow domain
  nSoilOnlyHyd            => indx_data%var(iLookINDEX%nSoilOnlyHyd )%dat(1)         ,& ! intent(in): [i4b]    number of hydrology variables in the soil domain
  ! state variables at the start of the time step
  mLayerMatricHead        => prog_data%var(iLookPROG%mLayerMatricHead)%dat           & ! intent(in): [dp(:)] matric head (m)
  ) ! associating variables with indices of model state variables
  ! -----------------------------------------------------------------------------------------------------
  ! initialize error control
  err=0; message='imposeConstraints/'

  ! ** limit temperature increment to zMaxTempIncrement
  if(any(abs(xInc(ixNrgOnly)) > zMaxTempIncrement))then
   iMax       = maxloc( abs(xInc(ixNrgOnly)) )                     ! index of maximum temperature increment
   xIncFactor = abs( zMaxTempIncrement/xInc(ixNrgOnly(iMax(1))) )  ! scaling factor for the iteration increment (-)
   xInc       = xIncFactor*xInc
  end if

  ! ** impose solution constraints for vegetation
  ! (stop just above or just below the freezing point if crossing)
  ! --------------------------------------------------------------------------------------------------------------------
  ! canopy temperatures

  if(ixVegNrg/=integerMissing)then

   ! initialize
   critDiff    = Tfreeze - stateVecTrial(ixVegNrg)
   crosTempVeg = .false.

   ! initially frozen (T < Tfreeze)
   if(critDiff > 0._rkind)then
    if(xInc(ixVegNrg) > critDiff)then
     crosTempVeg = .true.
     cInc        = critDiff + epsT  ! constrained temperature increment (K)
    end if

   ! initially unfrozen (T > Tfreeze)
   else
    if(xInc(ixVegNrg) < critDiff)then
     crosTempVeg = .true.
     cInc        = critDiff - epsT  ! constrained temperature increment (K)
    end if

   end if  ! switch between frozen and unfrozen

   ! scale iterations
   if(crosTempVeg)then
    xIncFactor  = cInc/xInc(ixVegNrg)  ! scaling factor for the iteration increment (-)
    xInc        = xIncFactor*xInc      ! scale iteration increments
   endif

  endif  ! if the state variable for canopy temperature is included within the state subset

  ! --------------------------------------------------------------------------------------------------------------------
  ! canopy liquid water

  if(ixVegHyd/=integerMissing)then

   ! check if new value of storage will be negative
   if(stateVecTrial(ixVegHyd)+xInc(ixVegHyd) < 0._rkind)then
    ! scale iteration increment
    cInc       = -0.5_rkind*stateVecTrial(ixVegHyd)                                  ! constrained iteration increment (K) -- simplified bi-section
    xIncFactor = cInc/xInc(ixVegHyd)                                              ! scaling factor for the iteration increment (-)
    xInc       = xIncFactor*xInc                                                  ! new iteration increment
   end if

  endif  ! if the state variable for canopy water is included within the state subset

  ! --------------------------------------------------------------------------------------------------------------------
  ! ** impose solution constraints for snow
  if(nSnowOnlyNrg > 0)then

   ! loop through snow layers
   checksnow: do iLayer=1,nSnow  ! necessary to ensure that NO layers rise above Tfreeze

    ! check of the data is mising
    if(ixSnowOnlyNrg(iLayer)==integerMissing) cycle

    ! check temperatures, and, if necessary, scale iteration increment
    iState = ixSnowOnlyNrg(iLayer)
    if(stateVecTrial(iState) + xInc(iState) > Tfreeze)then
     ! scale iteration increment
     cInc       = 0.5_rkind*(Tfreeze - stateVecTrial(iState) )        ! constrained temperature increment (K) -- simplified bi-section
     xIncFactor = cInc/xInc(iState)                                ! scaling factor for the iteration increment (-)
     xInc       = xIncFactor*xInc
    end if   ! if snow temperature > freezing

   end do checkSnow

  endif  ! if there are state variables for energy in the snow domain

  ! --------------------------------------------------------------------------------------------------------------------
  ! - check if drain more than what is available
  ! NOTE: change in total water is only due to liquid flux
  if(nSnowOnlyHyd>0)then

   ! loop through snow layers
   do iLayer=1,nSnow

    ! * check if the layer is included
    if(ixSnowOnlyHyd(iLayer)==integerMissing) cycle

    ! * get the layer temperature (from stateVecTrial if ixSnowOnlyNrg(iLayer) is within the state vector
    if(ixSnowOnlyNrg(iLayer)/=integerMissing)then
     scalarTemp = stateVecTrial( ixSnowOnlyNrg(iLayer) )

    ! * get the layer temperature from the last update
    else
     scalarTemp = prog_data%var(iLookPROG%mLayerTemp)%dat(iLayer)
    endif

    ! * get the volumetric fraction of liquid water
    select case( ixStateType_subset( ixSnowOnlyHyd(iLayer) ) )
     case(iname_watLayer); volFracLiq = fracliquid(scalarTemp,mpar_data%var(iLookPARAM%snowfrz_scale)%dat(1)) * stateVecTrial(ixSnowOnlyHyd(iLayer))
     case(iname_liqLayer); volFracLiq = stateVecTrial(ixSnowOnlyHyd(iLayer))
     case default; err=20; message=trim(message)//'expect ixStateType_subset to be iname_watLayer or iname_liqLayer for snow hydrology'; return
    end select

    ! * check that the iteration increment does not exceed volumetric liquid water content
    if(-xInc(ixSnowOnlyHyd(iLayer)) > volFracLiq)then
     drainFlag(iLayer) = .true.
     xInc(ixSnowOnlyHyd(iLayer)) = -0.5_rkind*volFracLiq
    endif

   end do  ! looping through snow layers

  endif   ! if there are state variables for liquid water in the snow domain

  ! --------------------------------------------------------------------------------------------------------------------
  ! ** impose solution constraints for soil temperature
  if(nSoilOnlyNrg>0)then
   do iLayer=1,nSoil

    ! - check if energy state is included
    if(ixSoilOnlyNrg(iLayer)==integerMissing) cycle

    ! - define index of the state variables within the state subset
    ixNrg = ixSoilOnlyNrg(iLayer)
    ixLiq = ixSoilOnlyHyd(iLayer)

    ! get the matric potential of total water
    if(ixLiq/=integerMissing)then
     xPsi00 = stateVecTrial(ixLiq) + xInc(ixLiq)
    else
     xPsi00 = mLayerMatricHead(iLayer)
    endif

    ! identify the critical point when soil begins to freeze (TcSoil)
    TcSoil = crit_soilT(xPsi00)

    ! get the difference from the current state and the crossing point (K)
    critDiff = TcSoil - stateVecTrial(ixNrg)

    ! * initially frozen (T < TcSoil)
    if(critDiff > 0._rkind)then

     ! (check crossing above zero)
     if(xInc(ixNrg) > critDiff)then
      crosFlag(iLayer) = .true.
      xInc(ixNrg) = critDiff + epsT  ! set iteration increment to slightly above critical temperature
     endif

    ! * initially unfrozen (T > TcSoil)
    else

     ! (check crossing below zero)
     if(xInc(ixNrg) < critDiff)then
      crosFlag(iLayer) = .true.
      xInc(ixNrg) = critDiff - epsT  ! set iteration increment to slightly below critical temperature
     endif

    endif  ! (switch between initially frozen and initially unfrozen)

   end do  ! (loop through soil layers)
  endif   ! (if there are both energy and liquid water state variables)

  ! ** impose solution constraints matric head
  if(size(ixMatOnly)>0)then
   do iState=1,size(ixMatOnly)

    ! - define index of the hydrology state variable within the state subset
    ixLiq = ixMatOnly(iState)

    ! - place constraint for matric head
    if(xInc(ixLiq) > 1._rkind .and. stateVecTrial(ixLiq) > 0._rkind)then
     xInc(ixLiq) = 1._rkind
    endif  ! if constraining matric head

   end do  ! (loop through soil layers)
  endif   ! (if there are both energy and liquid water state variables)

  ! end association with variables with indices of model state variables
  end associate

  end subroutine imposeConstraints

 end subroutine summaSolve




end module summaSolve_module
