// ignore_for_file: avoid_print
import 'package:dartcv4/dartcv.dart' as cv;

void main() {
  final image = cv.Mat.zeros(8, 8, cv.MatType.CV_8UC3);
  print('OpenCV ${image.cols}x${image.rows} loaded');
  image.dispose();
}
