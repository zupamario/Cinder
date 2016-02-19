#include "cinder/app/App.h"
#include "cinder/app/RendererGl.h"
#include "cinder/BSpline.h"
#include "cinder/cairo/Cairo.h"
#include "cinder/ImageIo.h"
#include "cinder/Utilities.h"

#include <vector>

#include "BSplineFit.h"

using namespace ci;
using namespace ci::app;
using std::vector;

class BSplineApp : public App {
 public:
	BSplineApp() : mTrackedPoint( -1 ), mDegree( 2 ), mOpen( true ), mLoop( false ), mNumControlPoints(3) {}
	
	int		findNearestPt( const vec2 &aPt );
	void	calcLength();
	
	void	mouseDown( MouseEvent event ) override;
	void	mouseUp( MouseEvent event ) override;
	void	mouseDrag( MouseEvent event ) override;
	void	keyDown( KeyEvent event ) override;

	void	drawBSpline( cairo::Context &ctx );
	void	draw() override;

	vector<vec2>		mPoints;
	int					mTrackedPoint;
	int					mDegree;
    int mNumControlPoints;
	bool				mOpen, mLoop;
    BSpline2f mSpline;
    std::vector<float> mParams;
};

void BSplineApp::mouseDown( MouseEvent event )
{
	const float MIN_CLICK_DISTANCE = 10.0f;
	if( event.isLeft() ) { // line
		vec2 clickPt = vec2( event.getPos() );
		int nearestIdx = findNearestPt( clickPt );
		if( ( nearestIdx < 0 ) || ( distance( mPoints[nearestIdx], clickPt ) > MIN_CLICK_DISTANCE ) ) {
			mPoints.push_back( vec2( event.getPos() ) );
			mTrackedPoint = -1;
		}
		else
			mTrackedPoint = nearestIdx;
		calcLength();
	}
}

void BSplineApp::mouseDrag( MouseEvent event )
{
	if( mTrackedPoint >= 0 ) {
		mPoints[mTrackedPoint] = vec2( event.getPos() );
		calcLength();
	}
}

void BSplineApp::mouseUp( MouseEvent event )
{
	mTrackedPoint = -1;
}

void BSplineApp::keyDown( KeyEvent event ) {
	if( event.getCode() == KeyEvent::KEY_ESCAPE ) {
		setFullScreen( false );
	}
	else if( event.getChar() == 'x' ) {
		mPoints.clear();
        mNumControlPoints = 3;
	}
	else if( event.getChar() == 'd' ) { // reduce the degree
		mDegree = ( mDegree > 1 ) ? mDegree - 1 : mDegree;
		calcLength();
	}
	else if( event.getChar() == 'D' ) { // increase the degree
		mDegree++;
		calcLength();
	}
	else if( event.getChar() == 'o' ) { // toggle between open/periodic
		mOpen = ! mOpen;
		calcLength();
	}
	else if( event.getChar() == 'l' ) { // toggle between looping
		mLoop = ! mLoop;
		calcLength();
	}
    else if (event.getChar() == 'p' ) {
        ++mNumControlPoints;
        calcLength();
    }
    else if (event.getChar() == 'P') {
        --mNumControlPoints;
        calcLength();
    }
	else if( event.getChar() == 'i' ) { // export to png image
		writeImage( getHomeDirectory() / "bsplineOutput.png", copyWindowSurface() );
	}
	else if( event.getChar() == 's' ) { // export to svg
		cairo::Context ctx( cairo::SurfaceSvg( getHomeDirectory() / "output.svg", getWindowWidth(), getWindowHeight() ) );
		drawBSpline( ctx );
	}
}

int BSplineApp::findNearestPt( const vec2 &aPt )
{
	if( mPoints.empty() )
		return -1;
	
	int result = 0;
	float nearestDist = distance( mPoints[0], aPt );
	for( size_t i = 1; i < mPoints.size(); ++i ) {
		if( distance( mPoints[i], aPt ) < nearestDist ) {
			result = i;
			nearestDist = distance( mPoints[i], aPt );
		}
	}
	
	return result;
}

void BSplineApp::calcLength()
{
	if( mPoints.size() > (size_t)mDegree+1 ) {
		//BSpline2f spline( mPoints, mDegree, mLoop, mOpen );
        mSpline = BSplineFit::fitBSpline<2,float>(mPoints, mDegree, mNumControlPoints, mParams);
		console() << "Arc Length: " << mSpline.getLength( 0, 1 ) << std::endl;
    } else {
        mSpline = BSpline2f();
    }
}

void BSplineApp::drawBSpline( cairo::Context &ctx )
{
	if( mPoints.size() > (size_t)mDegree+1 ) {
		ctx.setLineWidth( 2.5f );
		ctx.setSourceRgb( 1.0f, 0.5f, 0.25f );
		ctx.appendPath( Path2d( mSpline ) );
		ctx.stroke();
//		ctx.fill();
	}
}

void BSplineApp::draw()
{
	// clear to the background color
	cairo::Context ctx( cairo::createWindowSurface() );
	ctx.setSourceRgb( 0.0f, 0.1f, 0.2f );
	ctx.paint();
	
	// draw the sample points
	ctx.setSourceRgb( 1.0f, 1.0f, 0.0f );
	for( size_t p = 0; p < mPoints.size(); ++p ) {
		ctx.newSubPath();
		ctx.arc( mPoints[p], 2.5f, 0, 2 * 3.14159 );
	}
	ctx.stroke();
    
    if (mSpline.getNumControlPoints() <= 0) {
        return;
    }
    
    // draw the control points
    ctx.setSourceRgb( 1.0f, 0.0f, 0.0f );
    for( size_t p = 0; p < mSpline.getNumControlPoints(); ++p ) {
        ctx.newSubPath();
        ctx.arc( mSpline.getControlPoint(p), 2.5f, 0, 2 * 3.14159 );
    }
    ctx.stroke();

	if( mPoints.size() > (size_t)mDegree+1 ) {
		// draw the curve by approximating via linear subdivision as an alternative to the technique used in drawBSpline()
		ctx.setLineWidth( 8.0f );
		ctx.setSourceRgb( 0.25f, 1.0f, 0.5f );
		ctx.moveTo( mSpline.getPosition( 0 ) );
		for( float t = 0; t < 1.0f; t += 0.001f )
			ctx.lineTo( mSpline.getPosition( t ) );
		
		ctx.stroke();
		
		// draw points 1/4, 1/2 and 3/4 along the length
		//ctx.setSourceRgb( 0.0f, 0.7f, 1.0f );
		//float totalLength = mSpline.getLength( 0, 1 );
		//for( float p = 0.25f; p < 0.99f; p += 0.25f ) {
		//	ctx.newSubPath();
		//	ctx.arc( mSpline.getPosition( mSpline.getTime( p * totalLength ) ), 2.5f, 0, 2 * 3.14159f );
		//}
        
        // draw points at input parameter values
        ctx.setSourceRgb( 0.0f, 0.7f, 1.0f );
        for(int i = 0; i < mParams.size(); ++i) {
            ctx.newSubPath();
            ctx.arc( mSpline.getPosition( mParams[i] ), 1.5f, 0, 2 * 3.14159f );
        }
		
		ctx.stroke();
	}
    
    // draw the knots
    ctx.setSourceRgb(1.0f, 0.0f, 1.0f);
    for( size_t p = 0; p < mSpline.getNumControlPoints(); ++p ) {
        ctx.newSubPath();
        ctx.arc( mSpline.getPosition(mSpline.getKnot(p)), 3.5f, 0, 2 * 3.14159 );
    }
    ctx.fill();

	// draw the curve by bezier path
	//drawBSpline( ctx );
}

CINDER_APP( BSplineApp, Renderer2d )