#pragma once

#include "Include.h"

struct Camera {
	double focal_length;
	double sensor_width;

	dvec3 position;
	dvec3 rotation;
	dvec3 x_vector;
	dvec3 y_vector;
	dvec3 z_vector;

	Camera();

	void f_move(const double& i_x, const double& i_y, const double& i_z, const double& i_speed);

	dmat4 f_getViewMatrix();

	void f_rotate(const double& i_yaw, const double& i_pitch);

	void f_compile();
};