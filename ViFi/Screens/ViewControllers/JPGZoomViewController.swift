//
//  JPGZoomViewController.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit
import SDWebImage

class JPGZoomViewController: UIViewController, EFImageViewZoomDelegate {
    
    @IBOutlet weak var imageViewZoom: EFImageViewZoom!
    
    var imageURL = String()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.imageViewZoom._delegate = self
        self.imageViewZoom.imageView.sd_setImage(with: URL(string: imageURL, relativeTo: nil), placeholderImage: nil)
        self.imageViewZoom.contentMode = .left
        
    }
}
