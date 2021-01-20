# claude_top_level_library

import claude_low_level_library as low_level
import numpy as np
cimport numpy as np
cimport cython

ctypedef np.float64_t DTYPE_f

cpdef laplacian_2d(np.ndarray a,np.ndarray dx,DTYPE_f dy):
	cdef np.ndarray a_dx = (np.roll(a, -1, axis=1) - np.roll(a, 1, axis=1)) / dx[:, None]
	cdef np.ndarray output = (np.roll(a_dx, -1, axis=1) - np.roll(a_dx, 1, axis=1)) / dx[:, None]

	shift_south = np.pad(a, ((1,0), (0,0)), 'reflect', reflect_type='odd')[:-1,:]
	shift_north = np.pad(a, ((0,1), (0,0)), 'reflect', reflect_type='odd')[1:,:]
	a_dy = (shift_north - shift_south)/dy
	
	shift_south = np.pad(a_dy, ((1,0), (0,0)), 'reflect', reflect_type='odd')[:-1,:]
	shift_north = np.pad(a_dy, ((0,1), (0,0)), 'reflect', reflect_type='odd')[1:,:]
	output += (shift_north - shift_south)/dy

	return output

cpdef laplacian_3d(np.ndarray a,np.ndarray dx,DTYPE_f dy,np.ndarray pressure_levels):
	cdef np.ndarray output = low_level.scalar_gradient_x_matrix(low_level.scalar_gradient_x_matrix(a,dx),dx) + low_level.scalar_gradient_y_matrix(low_level.scalar_gradient_y_matrix(a,dy),dy) + low_level.scalar_gradient_z_matrix_primitive(low_level.scalar_gradient_z_matrix_primitive(a, pressure_levels),pressure_levels)
	return output

# divergence of (a*u) where a is a scalar field and u is the atmospheric velocity field
cpdef divergence_with_scalar(np.ndarray a, np.ndarray u, np.ndarray v, np.ndarray w, np.ndarray dx, DTYPE_f dy, np.ndarray pressure_levels):
	# https://scicomp.stackexchange.com/questions/27737/advection-equation-with-finite-difference-importance-of-forward-backward-or-ce

	output = (u + abs(u))*(a - np.roll(a, 1, axis=1))/dx[:, None, None] + (u - abs(u))*(np.roll(a, -1, axis=1) - a)/dx[:, None, None]
	output += (v + abs(v))*(a - np.pad(a, ((1,0), (0,0), (0,0)), 'reflect', reflect_type='odd')[:-1,:,:])/dy + (v - abs(v))*(np.pad(a, ((0,1), (0,0), (0,0)), 'reflect', reflect_type='odd')[1:,:,:] - a)/dy
	
	# output = 0.5*(a + abs(a))*(u - np.roll(u, 1, axis=1))/dx[:, None, None] + 0.5*(a - abs(a))*(np.roll(u, -1, axis=1) - u)/dx[:, None, None]
	# output += 0.5*(a + abs(a))*(v - np.pad(v, ((1,0), (0,0), (0,0)), 'reflect', reflect_type='odd')[:-1,:,:])/dy + 0.5*(a - abs(a))*(np.pad(v, ((0,1), (0,0), (0,0)), 'reflect', reflect_type='odd')[1:,:,:] - v)/dy

	return output

cpdef radiation_calculation(np.ndarray temperature_world, np.ndarray potential_temperature, np.ndarray pressure_levels, np.ndarray heat_capacity_earth, np.ndarray albedo, DTYPE_f insolation, np.ndarray lat, np.ndarray lon, np.int_t t, np.int_t dt, DTYPE_f day, DTYPE_f year, DTYPE_f axial_tilt):
	# calculate change in temperature of ground and atmosphere due to radiative imbalance
	cdef np.int_t nlat,nlon,nlevels,k
	cdef DTYPE_f fl = 0.1
	cdef DTYPE_f inv_day = 1/(24*60*60)

	nlat = lat.shape[0]	
	nlon = lon.shape[0]
	nlevels = pressure_levels.shape[0]

	cdef np.ndarray temperature_atmos = low_level.theta_to_t(potential_temperature,pressure_levels)
	cdef np.ndarray sun_lat = low_level.surface_optical_depth_array(lat)
	cdef np.ndarray optical_depth = np.outer(sun_lat, (fl*(pressure_levels/pressure_levels[0]) + (1-fl)*(pressure_levels/pressure_levels[0])**4))

	# calculate upward longwave flux, bc is thermal radiation at surface
	cpdef np.ndarray upward_radiation = np.zeros((nlat,nlon,nlevels))
	upward_radiation[:,:,0] = low_level.thermal_radiation_matrix(temperature_world)
	for k in np.arange(1,nlevels):
		upward_radiation[:,:,k] = (upward_radiation[:,:,k-1] - (optical_depth[:,None,k]-optical_depth[:,None,k-1])*(low_level.thermal_radiation_matrix(temperature_atmos[:,:,k])))/(1 + optical_depth[:,None,k-1] - optical_depth[:,None,k])

	# calculate downward longwave flux, bc is zero at TOA (in model)
	cpdef np.ndarray downward_radiation = np.zeros((nlat,nlon,nlevels))
	downward_radiation[:,:,-1] = 0
	for k in np.arange(0,nlevels-1)[::-1]:
		downward_radiation[:,:,k] = (downward_radiation[:,:,k+1] - low_level.thermal_radiation_matrix(temperature_atmos[:,:,k])*(optical_depth[:,None,k+1]-optical_depth[:,None,k]))/(1 + optical_depth[:,None,k] - optical_depth[:,None,k+1])
	
	# gradient of difference provides heating at each level
	cpdef np.ndarray Q = np.zeros((nlat,nlon,nlevels))
	cpdef np.ndarray z_gradient = low_level.scalar_gradient_z_matrix(upward_radiation - downward_radiation, pressure_levels)
	cpdef np.ndarray solar_matrix = low_level.solar_matrix(75,lat,lon,t,day, year, axial_tilt)
	for k in np.arange(nlevels):
		Q[:,:,k] = -287*temperature_atmos[:,:,k]*z_gradient[:,:,k]/(1000*pressure_levels[None,None,k])
		# approximate SW heating of ozone
		if pressure_levels[k] < 400*100:
			Q[:,:,k] += solar_matrix*inv_day*(100/pressure_levels[k])

	temperature_atmos += Q*dt

	# update surface temperature with shortwave radiation flux
	temperature_world += dt*((1-albedo)*(low_level.solar_matrix(insolation,lat,lon,t, day, year, axial_tilt) + downward_radiation[:,:,0]) - upward_radiation[:,:,0])/heat_capacity_earth 

	return temperature_world, low_level.t_to_theta(temperature_atmos,pressure_levels)

cpdef velocity_calculation(np.ndarray u,np.ndarray v,np.ndarray w,np.ndarray pressure_levels,np.ndarray geopotential,np.ndarray potential_temperature,np.ndarray coriolis,DTYPE_f gravity,np.ndarray dx,DTYPE_f dy,DTYPE_f dt):

	# calculate acceleration of atmosphere using primitive equations on beta-plane
	cpdef np.ndarray u_temp = dt*(-u*low_level.scalar_gradient_x_matrix(u, dx) - v*low_level.scalar_gradient_y_matrix(u, dy) - w*low_level.scalar_gradient_z_matrix_primitive(u, pressure_levels) + coriolis[:, None, None]*v - low_level.scalar_gradient_x_matrix(geopotential, dx) - 1E-5*u)
	cpdef np.ndarray v_temp = dt*(-u*low_level.scalar_gradient_x_matrix(v, dx) - v*low_level.scalar_gradient_y_matrix(v, dy) - w*low_level.scalar_gradient_z_matrix_primitive(v, pressure_levels) - coriolis[:, None, None]*u - low_level.scalar_gradient_y_matrix(geopotential, dy) - 1E-5*v)

	cpdef np.ndarray u_temp_sponge = dt*(-u*low_level.scalar_gradient_x_matrix(u, dx) - v*low_level.scalar_gradient_y_matrix(u, dy) - w*low_level.scalar_gradient_z_matrix_primitive(u, pressure_levels) - 1E-3*u)
	cpdef np.ndarray v_temp_sponge = dt*(-u*low_level.scalar_gradient_x_matrix(v, dx) - v*low_level.scalar_gradient_y_matrix(v, dy) - w*low_level.scalar_gradient_z_matrix_primitive(v, pressure_levels) - 1E-3*v)

	cpdef np.ndarray u_add = np.zeros_like(u_temp)
	cpdef np.ndarray v_add = np.zeros_like(v_temp)

	u_add[:,:,:17] += u_temp[:,:,:17]
	v_add[:,:,:17] += v_temp[:,:,:17]
	
	###

	u_add[:,:,17:] += u_temp_sponge[:,:,17:]
	v_add[:,:,17:] += v_temp_sponge[:,:,17:]	

	u_add[:2,:,:] *= 0
	u_add[-2:,:,:] *= 0
	v_add[:2,:,:] *= 0
	v_add[-2:,:,:] *= 0

	return u_add,v_add

cpdef w_calculation(np.ndarray u,np.ndarray v,np.ndarray w,np.ndarray pressure_levels,np.ndarray geopotential,np.ndarray potential_temperature,np.ndarray coriolis,DTYPE_f gravity,np.ndarray dx,DTYPE_f dy,DTYPE_f dt):
	cdef np.ndarray w_temp = np.zeros_like(u)
	cdef np.ndarray temperature_atmos = low_level.theta_to_t(potential_temperature,pressure_levels) 
	
	cdef np.int_t nlevels, k
	nlevels = len(pressure_levels)

	u_dx = low_level.scalar_gradient_x_matrix(u, dx)
	u_dy = low_level.scalar_gradient_y_matrix(v, dy)
	
	for k in np.arange(1,nlevels).tolist():
		# w_temp[:,:,k] = w_temp[:,:,k-1] - (pressure_levels[k] - pressure_levels[k-1]) * pressure_levels[k] * gravity * ( low_level.scalar_gradient_x_matrix(u, dx)[:,:,k] + low_level.scalar_gradient_y_matrix(v, dy)[:,:,k] )/(287*temperature_atmos[:,:,k])
		# w_temp[:,:,k] = - gravity*pressure_levels[k]*np.trapz(u_dx[:,:,:k]+u_dy[:,:,:k],pressure_levels[:k])/(287*temperature_atmos[:,:,k])
		w_temp[:,:,k] = - np.trapz(u_dx[:,:,:k]+u_dy[:,:,:k],pressure_levels[:k])
	
	w_temp[-1:,:,:] = 0
	w_temp[:1,:,:] = 0

	w += w_temp

	return w_temp

cpdef smoothing_3D(np.ndarray a,DTYPE_f smooth_parameter, DTYPE_f vert_smooth_parameter=0.5):
	cdef np.int_t nlat = a.shape[0]
	cdef np.int_t nlon = a.shape[1]
	cdef np.int_t nlevels = a.shape[2]
	smooth_parameter *= 0.5
	cdef np.ndarray test = np.fft.fftn(a)
	test[int(nlat*smooth_parameter):int(nlat*(1-smooth_parameter)),:,:] = 0
	test[:,int(nlon*smooth_parameter):int(nlon*(1-smooth_parameter)),:] = 0
	test[:,:,int(nlevels*vert_smooth_parameter):int(nlevels*(1-vert_smooth_parameter))] = 0
	return np.fft.ifftn(test).real

cpdef polar_planes(np.ndarray u,np.ndarray v,np.ndarray u_add,np.ndarray v_add,np.ndarray potential_temperature,np.ndarray geopotential,tuple grid_velocities,tuple indices,tuple grids,tuple coords,np.ndarray coriolis_plane_N,np.ndarray coriolis_plane_S,DTYPE_f grid_side_length,np.ndarray pressure_levels,np.ndarray lat,np.ndarray lon,DTYPE_f dt,DTYPE_f polar_grid_resolution,DTYPE_f gravity):

	x_dot_N,y_dot_N,x_dot_S,y_dot_S = grid_velocities[:]
	pole_low_index_N,pole_high_index_N,pole_low_index_S,pole_high_index_S = indices[:]
	grid_length_N,grid_length_S = grids[:]
	grid_lat_coords_N,grid_lon_coords_N,grid_x_values_N,grid_y_values_N,polar_x_coords_N,polar_y_coords_N,grid_lat_coords_S,grid_lon_coords_S,grid_x_values_S,grid_y_values_S,polar_x_coords_S,polar_y_coords_S = coords[:]
	
	### north pole ###
	north_temperature_data = np.flip(potential_temperature[pole_low_index_N:,:,:],axis=1)

	north_polar_plane_temperature = low_level.beam_me_up(lat[pole_low_index_N:],lon,north_temperature_data,grid_length_N,grid_lat_coords_N,grid_lon_coords_N)
	north_polar_plane_actual_temperature = low_level.theta_to_t(north_polar_plane_temperature,pressure_levels)
	
	north_geopotential_data = np.flip(geopotential[pole_low_index_N:,:,:],axis=1)
	north_polar_plane_geopotential = low_level.beam_me_up(lat[pole_low_index_N:],lon,north_geopotential_data,grid_length_N,grid_lat_coords_N,grid_lon_coords_N)
	
	# calculate local velocity on Cartesian grid (CARTESIAN)
	x_dot_add,y_dot_add = low_level.grid_velocities(north_polar_plane_geopotential,grid_side_length,coriolis_plane_N,x_dot_N,y_dot_N,polar_grid_resolution)

	x_dot_add *= dt
	y_dot_add *= dt

	x_dot_N += x_dot_add
	y_dot_N += y_dot_add

	# advect temperature field, isolate field to subtract from existing temperature field (CARTESIAN)
	north_polar_plane_addition = low_level.polar_plane_advect(north_polar_plane_temperature,x_dot_N,y_dot_N,polar_grid_resolution)

	# project velocities onto polar grid (POLAR)
	reproj_u_N, reproj_v_N = low_level.project_velocities_north(lon,x_dot_add,y_dot_add,pole_low_index_N,pole_high_index_N,grid_x_values_N,grid_y_values_N,polar_x_coords_N,polar_y_coords_N)

	# combine velocities with those calculated on polar grid (POLAR)
	reproj_u_N = low_level.combine_data(pole_low_index_N,pole_high_index_N,u_add[pole_low_index_N:,:,:],-reproj_u_N,lat)
	reproj_v_N = low_level.combine_data(pole_low_index_N,pole_high_index_N,v_add[pole_low_index_N:,:,:],reproj_v_N,lat)
	
	# reproj_u_N_new = np.roll(reproj_u_N,int(nlon/2),axis=1)

	# add the combined velocities to the global velocity arrays
	u_add[pole_low_index_N:,:,:] = reproj_u_N
	v_add[pole_low_index_N:,:,:] = reproj_v_N

	# re-project combined velocites to polar plane (prevent discontinuity at the boundary)
	# x_dot_N,y_dot_N = upload_velocities(lat[pole_low_index_N:],lon,reproj_u_N,reproj_v_N,grid_xx_N.shape[0],grid_lat_coords_N,grid_lon_coords_N)

	# north_temperature_resample = combine_data(pole_low_index_N,pole_high_index_N,north_temperature_data,beam_me_down(lon,north_polar_plane_temperature,pole_low_index_N,grid_x_values_N,grid_y_values_N,polar_x_coords_N,polar_y_coords_N))

	# project addition to temperature field onto polar grid (POLAR)
	north_reprojected_addition = low_level.beam_me_down(lon,north_polar_plane_addition,pole_low_index_N,grid_x_values_N,grid_y_values_N,polar_x_coords_N,polar_y_coords_N)
	north_reprojected_addition = np.flip(north_reprojected_addition,axis=1)

	###################################################################

	### south pole ###
	south_temperature_data = potential_temperature[:pole_low_index_S,:,:]
	south_polar_plane_temperature = low_level.beam_me_up(lat[:pole_low_index_S],lon,south_temperature_data,grid_length_S,grid_lat_coords_S,grid_lon_coords_S)
	south_polar_plane_actual_temperature = low_level.theta_to_t(south_polar_plane_temperature,pressure_levels)
	
	south_geopotential_data = geopotential[:pole_low_index_S,:,:]
	south_polar_plane_geopotential = low_level.beam_me_up(lat[:pole_low_index_S],lon,south_geopotential_data,grid_length_S,grid_lat_coords_S,grid_lon_coords_S)
	
	x_dot_add,y_dot_add = low_level.grid_velocities(south_polar_plane_geopotential,grid_side_length,coriolis_plane_S,x_dot_S,y_dot_S,polar_grid_resolution)

	x_dot_add *= dt
	y_dot_add *= dt

	x_dot_S += x_dot_add
	y_dot_S += y_dot_add

	south_polar_plane_addition = low_level.polar_plane_advect(south_polar_plane_temperature,x_dot_S,y_dot_S,polar_grid_resolution)

	reproj_u_S, reproj_v_S = low_level.project_velocities_south(lon,x_dot_add,y_dot_add,pole_low_index_S,pole_high_index_S,grid_x_values_S,grid_y_values_S,polar_x_coords_S,polar_y_coords_S)
	
	reproj_u_S = low_level.combine_data(pole_low_index_S,pole_high_index_S,u_add[:pole_low_index_S,:,:],reproj_u_S,lat)
	reproj_v_S = low_level.combine_data(pole_low_index_S,pole_high_index_S,v_add[:pole_low_index_S,:,:],reproj_v_S,lat)

	# south_temperature_resample = combine_data(pole_low_index_S,pole_high_index_S,south_temperature_data,beam_me_down(lon,south_polar_plane_temperature,pole_low_index_S,grid_x_values_S,grid_y_values_S,polar_x_coords_S,polar_y_coords_S))
	
	south_reprojected_addition = low_level.beam_me_down(lon,south_polar_plane_addition,pole_low_index_S,grid_x_values_S,grid_y_values_S,polar_x_coords_S,polar_y_coords_S)

	u_add[:pole_low_index_S,:,:] = reproj_u_S
	v_add[:pole_low_index_S,:,:] = reproj_v_S

	# x_dot_S,y_dot_S = low_level.upload_velocities(lat[:pole_low_index_S],lon,reproj_u_S,reproj_v_S,x_dot_S.shape[0],grid_lat_coords_S,grid_lon_coords_S)

	return u_add,v_add,north_reprojected_addition,south_reprojected_addition,x_dot_N,y_dot_N,x_dot_S,y_dot_S

cpdef w_plane(x_dot,y_dot,temperature,pressure_levels,polar_grid_resolution,gravity):
	cdef np.ndarray w_temp = np.zeros_like(x_dot)
	cdef np.int_t k
	temperature = low_level.theta_to_t(temperature,pressure_levels)

	x_dot_dx = low_level.grid_x_gradient_matrix(x_dot, polar_grid_resolution)
	y_dot_dy = low_level.grid_y_gradient_matrix(y_dot, polar_grid_resolution)
	
	for k in np.arange(1,len(pressure_levels)).tolist():
		# w_temp[:,:,k] = - gravity*pressure_levels[k]*np.trapz(x_dot_dx[:,:,:k]+y_dot_dy[:,:,:k],pressure_levels[:k])/(287*temperature[:,:,k])
		w_temp[:,:,k] = - np.trapz(x_dot_dx[:,:,:k]+y_dot_dy[:,:,:k],pressure_levels[:k])
	
	return w_temp
	