
void computeIMU () {
  uint8_t axis;
  static int16_t gyroADCprevious[3] = {0,0,0};
  int16_t gyroADCp[3];
  int16_t gyroADCinter[3];
//  static int16_t lastAccADC[3] = {0,0,0};
  static uint32_t timeInterleave = 0;
#if defined(TRI)
  static int16_t gyroYawSmooth = 0;
#endif

  //we separate the 2 situations because reading gyro values with a gyro only setup can be acchieved at a higher rate
  //gyro+nunchuk: we must wait for a quite high delay betwwen 2 reads to get both WM+ and Nunchuk data. It works with 3ms
  //gyro only: the delay to read 2 consecutive values can be reduced to only 0.65ms
  if (!ACC && nunchuk) {
    annexCode();
    while((micros()-timeInterleave)<INTERLEAVING_DELAY) ; //interleaving delay between 2 consecutive reads
    timeInterleave=micros();
    WMP_getRawADC();
    getEstimatedAttitude(); // computation time must last less than one interleaving delay
    #if BARO
      getEstimatedAltitude();
    #endif 
    while((micros()-timeInterleave)<INTERLEAVING_DELAY) ; //interleaving delay between 2 consecutive reads
    timeInterleave=micros();
    while(WMP_getRawADC() != 1) ; // For this interleaving reading, we must have a gyro update at this point (less delay)

    for (axis = 0; axis < 3; axis++) {
      // empirical, we take a weighted value of the current and the previous values
      // /4 is to average 4 values, note: overflow is not possible for WMP gyro here
      gyroData[axis] = (gyroADC[axis]*3+gyroADCprevious[axis]+2)/4;
      gyroADCprevious[axis] = gyroADC[axis];
    }
  } else {
    if (ACC) {
      ACC_getADC();
      getEstimatedAttitude();
      if (BARO) getEstimatedAltitude();
    }
    if (GYRO) Gyro_getADC(); else WMP_getRawADC();
    for (axis = 0; axis < 3; axis++)
      gyroADCp[axis] =  gyroADC[axis];
    timeInterleave=micros();
    annexCode();
    if ((micros()-timeInterleave)>650) {
       annex650_overrun_count++;
    } else {
       while((micros()-timeInterleave)<650) ; //empirical, interleaving delay between 2 consecutive reads
    }
    if (GYRO) Gyro_getADC(); else WMP_getRawADC();
    for (axis = 0; axis < 3; axis++) {
      gyroADCinter[axis] =  gyroADC[axis]+gyroADCp[axis];
      // empirical, we take a weighted value of the current and the previous values
      gyroData[axis] = (gyroADCinter[axis]+gyroADCprevious[axis]+1)/3;
      gyroADCprevious[axis] = gyroADCinter[axis]/2;
      if (!ACC) accADC[axis]=0;
    }
  }
  #if defined(TRI)
    gyroData[YAW] = (gyroYawSmooth*2+gyroData[YAW]+1)/3;
    gyroYawSmooth = gyroData[YAW];
  #endif
}

// **************************************************
// Simplified IMU based on "Complementary Filter"
// Inspired by http://starlino.com/imu_guide.html
//
// adapted by ziss_dm : http://wbb.multiwii.com/viewtopic.php?f=8&t=198
//
// The following ideas was used in this project:
// 1) Rotation matrix: http://en.wikipedia.org/wiki/Rotation_matrix
// 2) Small-angle approximation: http://en.wikipedia.org/wiki/Small-angle_approximation
// 3) C. Hastings approximation for atan2()
// 4) Optimization tricks: http://www.hackersdelight.org/
//
// Currently Magnetometer uses separate CF which is used only
// for heading approximation.
//
// Modified: 19/04/2011  by ziss_dm
// Version: V1.1
//
// code size deduction and tmp vector intermediate step for vector rotation computation: October 2011 by Alex
// **************************************************

//******  advanced users settings *******************
/* Set the Low Pass Filter factor for ACC */
/* Increasing this value would reduce ACC noise (visible in GUI), but would increase ACC lag time*/
/* Comment this if  you do not want filter at all.*/
/* Default WMC value: 8*/
#define ACC_LPF_FACTOR 8

/* Set the Low Pass Filter factor for Magnetometer */
/* Increasing this value would reduce Magnetometer noise (not visible in GUI), but would increase Magnetometer lag time*/
/* Comment this if  you do not want filter at all.*/
/* Default WMC value: n/a*/
#define MG_LPF_FACTOR 4

/* Set the Gyro Weight for Gyro/Acc complementary filter */
/* Increasing this value would reduce and delay Acc influence on the output of the filter*/
/* Default WMC value: 300*/
#define GYR_CMPF_FACTOR 500.0f

/* Set the Gyro Weight for Gyro/Magnetometer complementary filter */
/* Increasing this value would reduce and delay Magnetometer influence on the output of the filter*/
/* Default WMC value: n/a*/
#define GYR_CMPFM_FACTOR 500.0f
//#define GYR_CMPFM_FACTOR 0.1f // DEBUG: test heading by MAG only (without gyro)

//****** end of advanced users settings *************

#define INV_GYR_CMPF_FACTOR   (1.0f / (GYR_CMPF_FACTOR  + 1.0f))
#define INV_GYR_CMPFM_FACTOR  (1.0f / (GYR_CMPFM_FACTOR + 1.0f))
#if GYRO
  #define GYRO_SCALE ((2380 * PI)/((32767.0f / 4.0f ) * 180.0f * 1000000.0f)) //should be 2279.44 but 2380 gives better result
  // +-2000/sec deg scale
  //#define GYRO_SCALE ((200.0f * PI)/((32768.0f / 5.0f / 4.0f ) * 180.0f * 1000000.0f) * 1.5f)     
  // +- 200/sec deg scale
  // 1.5 is emperical, not sure what it means
  // should be in rad/sec
#else
  #define GYRO_SCALE (1.0f/200e6f)
  // empirical, depends on WMP on IDG datasheet, tied of deg/ms sensibility
  // !!!!should be adjusted to the rad/sec
#endif 
// Small angle approximation
#define ssin(val) (val)
#define scos(val) 1.0f

typedef struct fp_vector {
  float X;
  float Y;
  float Z;
} t_fp_vector_def;

typedef union {
  float   A[3];
  t_fp_vector_def V;
} t_fp_vector;

// alexmos: atan2 in radians
inline float _atan2rad(float y, float x) {
  #define fp_is_neg(val) ((((byte*)&val)[3] & 0x80) != 0)
  float z = y / x;
  int16_t zi = abs(int16_t(z * 100)); 
  int8_t y_neg = fp_is_neg(y);
  if ( zi < 100 ){
    if (zi > 10) 
     z = z / (1.0f + 0.28f * z * z);
   if (fp_is_neg(x)) {
     if (y_neg) z -= PI;
     else z += PI;
   }
  } else {
   z = (PI / 2.0f) - z / (z * z + 0.28f);
   if (y_neg) z -= PI;
  }
  return z;
}

int16_t _atan2(float y, float x){
	return _atan2rad(y, x) * (180.0f / PI * 10); 
}

// Rotate Estimated vector(s) with small angle approximation, according to the gyro data
void rotateV(struct fp_vector *v,float* delta) {
  fp_vector v_tmp = *v;
  v->Z -= delta[ROLL]  * v_tmp.X + delta[PITCH] * v_tmp.Y;
  v->X += delta[ROLL]  * v_tmp.Z - delta[YAW]   * v_tmp.Y;
  v->Y += delta[PITCH] * v_tmp.Z + delta[YAW]   * v_tmp.X; 
}

// alexmos: need it later
static t_fp_vector EstG;

void getEstimatedAttitude(){
  uint8_t axis;
  int16_t accMag = 0;
#if MAG
  static t_fp_vector EstM;
#endif
#if defined(MG_LPF_FACTOR)
  static int16_t mgSmooth[3]; 
#endif
#if defined(ACC_LPF_FACTOR)
  static int16_t accTemp[3];  //projection of smoothed and normalized magnetic vector on x/y/z axis, as measured by magnetometer
#endif
  //static uint16_t previousT;
  //uint16_t currentT = micros();
  float scale, deltaGyroAngle[3];

  scale = cycleTime * GYRO_SCALE;
  //previousT = currentT;

  // Initialization
  for (axis = 0; axis < 3; axis++) {
    deltaGyroAngle[axis] = gyroADC[axis]  * scale;
    #if defined(ACC_LPF_FACTOR)
      accTemp[axis] = (accTemp[axis] - (accTemp[axis] >>4)) + accADC[axis];
      accSmooth[axis] = accTemp[axis]>>4;
      #define ACC_VALUE accSmooth[axis]
    #else  
      accSmooth[axis] = accADC[axis];
      #define ACC_VALUE accADC[axis]
    #endif
    accMag += (ACC_VALUE * 10 / (int16_t)acc_1G) * (ACC_VALUE * 10 / (int16_t)acc_1G);
    #if MAG
      #if defined(MG_LPF_FACTOR)
        mgSmooth[axis] = (mgSmooth[axis] * (MG_LPF_FACTOR - 1) + magADC[axis]) / MG_LPF_FACTOR; // LPF for Magnetometer values
        #define MAG_VALUE mgSmooth[axis]
      #else  
        #define MAG_VALUE magADC[axis]
      #endif
    #endif
  }

  rotateV(&EstG.V,deltaGyroAngle);
  #if MAG
    rotateV(&EstM.V,deltaGyroAngle);
  #endif 

  if ( abs(accSmooth[ROLL])<acc_25deg && abs(accSmooth[PITCH])<acc_25deg && accSmooth[YAW]>0)
    smallAngle25 = 1;
  else
    smallAngle25 = 0;

  // Apply complimentary filter (Gyro drift correction)
  // If accel magnitude >1.4G or <0.6G and ACC vector outside of the limit range => we neutralize the effect of accelerometers in the angle estimation.
  // To do that, we just skip filter, as EstV already rotated by Gyro
  if ( ( 36 < accMag && accMag < 196 ) || smallAngle25 )
    for (axis = 0; axis < 3; axis++) {
      int16_t acc = ACC_VALUE;
      #if not defined(TRUSTED_ACCZ)
        if (smallAngle25 && axis == YAW)
          //We consider ACCZ = acc_1G when the acc on other axis is small.
          //It's a tweak to deal with some configs where ACC_Z tends to a value < acc_1G when high throttle is applied.
          //This tweak applies only when the multi is not in inverted position
          acc = acc_1G;      
      #endif
      EstG.A[axis] = (EstG.A[axis] * GYR_CMPF_FACTOR + acc) * INV_GYR_CMPF_FACTOR;
    }
  #if MAG
    for (axis = 0; axis < 3; axis++)
      EstM.A[axis] = (EstM.A[axis] * GYR_CMPFM_FACTOR  + MAG_VALUE) * INV_GYR_CMPFM_FACTOR;
  #endif
  
  // Attitude of the estimated vector
  angle[ROLL]  =  _atan2(EstG.V.X , EstG.V.Z) ;
  angle[PITCH] =  _atan2(EstG.V.Y , EstG.V.Z) ;
  #if MAG
    // Attitude of the cross product vector GxM
    heading = _atan2( EstG.V.X * EstM.V.Z - EstG.V.Z * EstM.V.X , EstG.V.Z * EstM.V.Y - EstG.V.Y * EstM.V.Z  ) / 10;
  #endif
}


/* alexmos: baro + ACC altitude estimator */
/* It outputs altitude, velocity and 'pure' acceleration on Z axis (with 1G substracted) */
/* Set the trust ACC compared to BARO. Default is 300. 
/* For good ACC sensor and noisy BARO increase it. If both are noise - sorry :) */
#define ACC_BARO_CMPF 500.0f
/* PID values to correct 'pure' ACC (it should be zero without any motion) */
#define ACC_BARO_ERR_P 50.0f   
#define ACC_BARO_ERR_I (ACC_BARO_ERR_P * 0.001f)
#define ACC_BARO_ERR_D (ACC_BARO_ERR_P * 0.005f)
/* Velocity dumper. Higher values prevents  oscillations in case of high PID's */
#define VEL_DUMP_FACTOR 500.0f
/* Output some vars to GUI (replacing 'MAG' and 'heading') */
#define ALT_DEBUG

void getEstimatedAltitude(){
  static uint16_t dTime = 0;
  static int8_t initDone = 0;
  static float alt = 0; // cm
  static float vel = 0; // cm/sec
 	static float err = 0, errI = 0, errPrev = 0; // error integrator
  static float accScale; // config variables
  float accZ;
  
  //BaroAlt = 0; // TODO: remove

  // get alt from baro on sysem start
  if(!initDone && BaroAlt != 0) {
  	alt = BaroAlt;
  	accScale = 9.80665f / acc_1G / 10000.0f;
  	initDone = 1;
  }
  
  // error between estimated alt and BARO alt
  // TODO: take cycleTime and acc_1G into account to leave PID settings invariant between different sensors and setups
  err = (alt - BaroAlt)/ACC_BARO_CMPF; // P term of error
  errI+= err * ACC_BARO_ERR_I; // I term of error
	
  if(abs(EstG.V.Z) > acc_1G/2) { 
  	// angle is good to take ACC.Z into account.  
  	// (if we skip this step - no big problem, altitude will be corrected by baro only)

	  /* Project ACC vector A to 'global' Z axis (estimated by gyro vector G) and correct static bias (I term of PID)
	  /* Background:
	  /*  	accZ = Az * |G| / Gz
	  /* 		|G| = sqrt(Gx*Gx + Gy*Gy + Gz*Gz)
	  /* 		sqrt(a*a + b*b + c*c) =~ a + (b*b + c*c)/2/a  if b + c << a (talor series approximation)
	  /* TODO: use integer arithmetic
	  */
	  //accZ =  accADC[YAW] * (1.0f + (fsq(EstG.V.X) + fsq(EstG.V.Y))/2.0f/fsq(EstG.V.Z)) - errI;
	  // --OR-- approximation using InvSqrt. Correct error before projection.
	  //accZ = (accADC[YAW] - errI) / InvSqrt(fsq(EstG.V.X) + fsq(EstG.V.Y) + fsq(EstG.V.Z)) / EstG.V.Z;
	  // --OR-- the same, but correct ACC error after projection
	  accZ = accADC[YAW] / InvSqrt(fsq(EstG.V.X) + fsq(EstG.V.Y) + fsq(EstG.V.Z)) / EstG.V.Z - errI;
	  
	  // Integrator - velocity, cm/sec
	  // Apply P and D terms of PID correction
	  // D term of real error is VERY noisy, so use Dterm = vel (it will lead vel to zero)
	  vel+= (accZ - acc_1G - err*ACC_BARO_ERR_P - vel*ACC_BARO_ERR_D) * cycleTime * accScale;
	  
	  // Integrator - altitude, cm
	  alt+= vel * cycleTime / 1000000;

	  // Dump velocity to prevent oscillations
	  //vel*= VEL_DUMP_FACTOR/(VEL_DUMP_FACTOR + 1);
  }

  // Apply ACC->BARO complimentary filter
  alt-= err;
  errPrev = err;
  
  EstAlt = alt;
  
  // debug to GUI
  #ifdef ALT_DEBUG
	  magADC[ROLL] = (accZ - acc_1G)*3;
	  magADC[PITCH] = errI*3;
	  magADC[YAW] = err*300;
	  heading = vel;
	#endif
}

int32_t isq(int16_t x){return x * x;}
float fsq(float x){return x * x;}







float InvSqrt (float x){ 
  union{  
    int32_t i;  
    float   f; 
  } conv; 
  conv.f = x; 
  conv.i = 0x5f3759df - (conv.i >> 1); 
  return 0.5f * conv.f * (3.0f - x * conv.f * conv.f);
} 

#define UPDATE_INTERVAL 25000    // 40hz update rate (20hz LPF on acc)
#define INIT_DELAY      4000000  // 4 sec initialization delay
#define Kp1 0.55f                // PI observer velocity gain 
#define Kp2 1.0f                 // PI observer position gain
#define Ki  0.001f               // PI observer integral gain (bias cancellation)
#define dt  (UPDATE_INTERVAL / 1000000.0f)

void getEstimatedAltitude2(){
  static uint8_t inited = 0;
  static int16_t AltErrorI = 0;
  static float AccScale  = 0.0f;
  static uint32_t deadLine = INIT_DELAY;
  int16_t AltError;
  int16_t InstAcc;
  int16_t Delta;
  
  if (currentTime < deadLine) return;
  deadLine = currentTime + UPDATE_INTERVAL; 
  // Soft start

  if (!inited) {
    inited = 1;
    EstAlt = BaroAlt;
    EstVelocity = 0;
    AltErrorI = 0;
    AccScale = 100 * 9.80665f / acc_1G;
  }
  // Estimation Error
  AltError = BaroAlt - EstAlt; 
  AltErrorI += AltError;
  AltErrorI=constrain(AltErrorI,-25000,+25000);
  // Gravity vector correction and projection to the local Z
  //InstAcc = (accADC[YAW] * (1 - acc_1G * InvSqrt(isq(accADC[ROLL]) + isq(accADC[PITCH]) + isq(accADC[YAW])))) * AccScale + (Ki) * AltErrorI;
  #if defined(TRUSTED_ACCZ)
    InstAcc = (accADC[YAW] * (1 - acc_1G * InvSqrt(isq(accADC[ROLL]) + isq(accADC[PITCH]) + isq(accADC[YAW])))) * AccScale +  AltErrorI / 1000;
  #else
    InstAcc = AltErrorI / 1000;
  #endif
  
  // Integrators
  Delta = InstAcc * dt + (Kp1 * dt) * AltError;
  EstAlt += (EstVelocity/5 + Delta) * (dt / 2) + (Kp2 * dt) * AltError;
  EstVelocity += Delta*10;
}

  
  
  
  
  
