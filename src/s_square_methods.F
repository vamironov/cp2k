!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright (C) 2000 - 2020  CP2K developers group                                               !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief methods related to S**2 (ie. spin)
!> \par History
!>      03.2006, copied compute_s_square from qs_scf_post  [Joost VandeVondele]
!> \author Joost VandeVondele
! **************************************************************************************************
MODULE s_square_methods

   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_control_types,                ONLY: s2_restraint_type
   USE cp_dbcsr_operations,             ONLY: cp_dbcsr_sm_fm_multiply
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_p_type,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_gemm_interface,               ONLY: cp_gemm
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_p_type
   USE input_constants,                 ONLY: do_s2_constraint,&
                                              do_s2_restraint
   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_sum
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_p_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! *** Global parameters ***

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 's_square_methods'

   PUBLIC :: compute_s_square, s2_restraint

CONTAINS

! **************************************************************************************************
!> \brief compute s square of the single determinant defined by the
!>       by the spin up and spin down orbitals
!> \param mos , matrix_s : input
!> \param matrix_s ...
!> \param s_square , s_square_ideal : out
!> \param s_square_ideal ...
!> \param mo_derivs inout if present, add the derivative of s_square wrt mos to mo_derivs
!> \param strength ...
!> \par History
!>      07.2004 created [ Joost VandeVondele ]
!> \note
!>       see Eq. 2.271 in Modern Quantum Chemistry
!>       Szabo and Ostlund
! **************************************************************************************************
   SUBROUTINE compute_s_square(mos, matrix_s, s_square, s_square_ideal, &
                               mo_derivs, strength)
      TYPE(mo_set_p_type), DIMENSION(:), POINTER         :: mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      REAL(KIND=dp)                                      :: s_square, s_square_ideal
      TYPE(cp_fm_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: mo_derivs
      REAL(KIND=dp), OPTIONAL                            :: strength

      CHARACTER(len=*), PARAMETER :: routineN = 'compute_s_square', &
         routineP = moduleN//':'//routineN

      INTEGER                                            :: handle, i, j, na, nalpha, nb, nbeta, &
                                                            ncol_local, nrow, nrow_local
      LOGICAL                                            :: uniform_occupation
      REAL(KIND=dp)                                      :: tmp
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: local_data
      TYPE(cp_blacs_env_type), POINTER                   :: context
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct_tmp
      TYPE(cp_fm_type), POINTER                          :: c_alpha, c_beta, matrix_overlap, &
                                                            matrix_sc_a, matrix_sc_b
      TYPE(cp_para_env_type), POINTER                    :: para_env

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct_tmp, matrix_sc_a, matrix_sc_b, matrix_overlap, para_env, context, local_data)

      SELECT CASE (SIZE(mos))
      CASE (1)
         s_square = 0.0_dp
         s_square_ideal = 0.0_dp
         ! let's not do this
         CPASSERT(PRESENT(mo_derivs))
      CASE (2)
         CALL get_mo_set(mo_set=mos(1)%mo_set, mo_coeff=c_alpha, homo=nalpha, uniform_occupation=uniform_occupation)
         IF (.NOT. uniform_occupation) CPWARN("Found non-uniform occupation")
         CALL get_mo_set(mo_set=mos(2)%mo_set, mo_coeff=c_beta, homo=nbeta, uniform_occupation=uniform_occupation)
         IF (.NOT. uniform_occupation) CPWARN("Found non-uniform occupation")
         CALL cp_fm_get_info(c_alpha, ncol_global=na)
         CALL cp_fm_get_info(c_beta, ncol_global=nb)
         s_square_ideal = REAL((nalpha - nbeta)*(nalpha - nbeta + 2), KIND=dp)/4.0_dp
         ! create overlap matrix
         CALL cp_fm_get_info(c_alpha, para_env=para_env, context=context)
         CALL cp_fm_struct_create(fm_struct_tmp, para_env=para_env, context=context, &
                                  nrow_global=na, ncol_global=nb)
         CALL cp_fm_create(matrix_overlap, fm_struct_tmp, name="matrix_overlap")
         CALL cp_fm_struct_release(fm_struct_tmp)
         ! create S C_beta and compute overlap
         CALL cp_fm_get_info(c_beta, matrix_struct=fm_struct_tmp, nrow_global=nrow)
         CALL cp_fm_create(matrix_sc_b, fm_struct_tmp, name="matrix_sc_beta")
         CALL cp_dbcsr_sm_fm_multiply(matrix_s(1)%matrix, c_beta, matrix_sc_b, nb)
         CALL cp_gemm('T', 'N', na, nb, nrow, 1.0_dp, c_alpha, matrix_sc_b, 0.0_dp, matrix_overlap)
         ! invoke formula 2.271
         CALL cp_fm_get_info(matrix_overlap, &
                             local_data=local_data, &
                             nrow_local=nrow_local, &
                             ncol_local=ncol_local)
         tmp = 0.0_dp
         DO j = 1, ncol_local
         DO i = 1, nrow_local
            tmp = tmp + local_data(i, j)**2
         ENDDO
         ENDDO
         CALL mp_sum(tmp, para_env%group)
         s_square = s_square_ideal + nb - tmp
         IF (PRESENT(mo_derivs)) THEN
            ! this gets really wrong for fractional occupations
            CPASSERT(SIZE(mo_derivs, 1) == 2)
            CALL get_mo_set(mo_set=mos(1)%mo_set, uniform_occupation=uniform_occupation)
            CPASSERT(uniform_occupation)
            CALL get_mo_set(mo_set=mos(2)%mo_set, uniform_occupation=uniform_occupation)
            CPASSERT(uniform_occupation)
            CALL cp_gemm('N', 'T', nrow, na, nb, -1.0_dp*strength, matrix_sc_b, matrix_overlap, 1.0_dp, mo_derivs(1)%matrix)
            CALL cp_fm_release(matrix_sc_b)
            CALL cp_fm_get_info(c_alpha, matrix_struct=fm_struct_tmp)
            CALL cp_fm_create(matrix_sc_a, fm_struct_tmp, name="matrix_sc_alpha")
            CALL cp_dbcsr_sm_fm_multiply(matrix_s(1)%matrix, c_alpha, matrix_sc_a, na)
            CALL cp_gemm('N', 'N', nrow, nb, na, -1.0_dp*strength, matrix_sc_a, matrix_overlap, 1.0_dp, mo_derivs(2)%matrix)
            CALL cp_fm_release(matrix_sc_a)
            CALL cp_fm_release(matrix_overlap)
         ELSE
            CALL cp_fm_release(matrix_sc_b)
            CALL cp_fm_release(matrix_overlap)
         ENDIF
      CASE DEFAULT
         CPABORT("alpha, beta, what else ?")
      END SELECT

      CALL timestop(handle)

   END SUBROUTINE compute_s_square

! **************************************************************************************************
!> \brief restrains/constrains the value of s2 in a calculation
!> \param mos input
!> \param matrix_s input
!> \param mo_derivs inout if present, add the derivative of s_square wrt mos to mo_derivs
!> \param energy ...
!> \param s2_restraint_control ...
!> \param just_energy ...
!> \par History
!>      07.2004 created [ Joost VandeVondele ]
! **************************************************************************************************
   SUBROUTINE s2_restraint(mos, matrix_s, mo_derivs, energy, &
                           s2_restraint_control, just_energy)

      TYPE(mo_set_p_type), DIMENSION(:), POINTER         :: mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      TYPE(cp_fm_p_type), DIMENSION(:), POINTER          :: mo_derivs
      REAL(kind=dp)                                      :: energy
      TYPE(s2_restraint_type), POINTER                   :: s2_restraint_control
      LOGICAL                                            :: just_energy

      CHARACTER(len=*), PARAMETER :: routineN = 's2_restraint', routineP = moduleN//':'//routineN

      INTEGER                                            :: handle
      REAL(kind=dp)                                      :: s_square, s_square_ideal

      CALL timeset(routineN, handle)

      SELECT CASE (s2_restraint_control%functional_form)
      CASE (do_s2_constraint)
         IF (just_energy) THEN
            CALL compute_s_square(mos, matrix_s, s_square, s_square_ideal)
         ELSE
            CALL compute_s_square(mos, matrix_s, s_square, s_square_ideal, &
                                  mo_derivs, s2_restraint_control%strength)
         ENDIF
         energy = s2_restraint_control%strength*(s_square - s2_restraint_control%target)
         s2_restraint_control%s2_order_p = s_square
      CASE (do_s2_restraint) ! not yet implemented
         CPABORT("")
      CASE DEFAULT
         CPABORT("")
      END SELECT

      CALL timestop(handle)

   END SUBROUTINE s2_restraint

END MODULE s_square_methods
